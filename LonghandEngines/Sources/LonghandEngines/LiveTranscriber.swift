import Foundation
@preconcurrency import AVFoundation
import Observation
import OSLog
import Speech
import LonghandKit

/// The words of a take as they are said, from Apple's on-device recognizer,
/// for the record sheet. A preview and nothing more: the transcript is made
/// afterwards from the whole file by the same pipeline as always, with
/// speakers, and this text never reaches a checkpoint, the overlay, or an
/// export.
///
/// Only the languages `SpeechTranscriber` covers can do this. Whisper reads
/// a thirty-second window at a time and cannot stream, so a take in Hebrew
/// or Russian, or with the mixed-language setting, records without a
/// preview and says nothing about it, which is the honest option.
///
/// The recognizer's assets are the same ones the final pass needs. If they
/// are not installed yet, they are fetched while the take records, with the
/// sheet saying so; the preview then starts from that point on. The take is
/// never held for it.
@MainActor
@Observable
public final class LiveTranscript {

    public enum Status: Equatable, Sendable {
        /// Assets are being fetched or the analyzer is starting.
        case preparing
        case listening
        /// Audio is still being recorded but not previewed: the app is in the
        /// background, or the device asked for a lighter load.
        case suspended
        /// Nothing more will come; what is shown is what there is.
        case stopped
        case failed(String)
    }

    public private(set) var text = LiveTranscriptText()
    public private(set) var status: Status = .preparing
    /// "English", for the caption, in the user's own language.
    public let languageName: String

    nonisolated init(languageName: String) {
        self.languageName = languageName
    }

    fileprivate func apply(_ text: LiveTranscriptText) {
        self.text = text
    }

    fileprivate func setStatus(_ status: Status) {
        self.status = status
    }
}

/// Owns the analyzer and the audio stream behind a `LiveTranscript`.
///
/// Audio arrives on the capture's audio thread through `feed`, is converted
/// to the analyzer's format there, and is handed to an `AsyncStream` with a
/// bounded buffer: a recognizer that falls behind loses old audio from the
/// preview, never from the file, and never stalls the thread that writes it.
public nonisolated final class LiveTranscriber: @unchecked Sendable {

    public static let settingsKey = "liveTranscriptPreview"

    /// **On by default** where it can work at all: it costs the take nothing
    /// and shows that the microphone hears what was meant.
    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingsKey) as? Bool ?? true
    }

    /// Settled words kept on the sheet. A meeting runs for an hour; the
    /// label need not.
    static let keptWords = 400

    public let output: LiveTranscript
    private let locale: Locale
    private let transcriber: SpeechTranscriber
    private var analyzer: SpeechAnalyzer?
    private var collector: Task<Void, Never>?

    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var text = LiveTranscriptText()
    private var suspended = false
    private var finished = false

    private init(locale: Locale, languageName: String) {
        self.locale = locale
        output = LiveTranscript(languageName: languageName)
        // Volatile results are what makes it live: a guess for the words
        // being said now, revised until the recognizer settles on them.
        transcriber = SpeechTranscriber(locale: locale,
                                        transcriptionOptions: [],
                                        reportingOptions: [.volatileResults],
                                        attributeOptions: [])
    }

    // MARK: - Availability

    /// The locale the preview would use for the saved transcription default,
    /// or nil when there is no preview for it: the mixed-language setting,
    /// a Whisper language, or a device (a simulator) reporting no locales.
    /// `setting` is the `defaultImportLanguage` value: "system", "auto", or
    /// a language code.
    public static func locale(forLanguageSetting setting: String) async -> Locale? {
        guard isEnabled, setting != JobPipeline.autoDetectLanguage else { return nil }
        let target = setting == TranscriptionLanguages.systemSentinel
            ? Locale.current.language
            : Locale(identifier: setting).language
        guard let code = target.languageCode?.identifier else { return nil }
        let supported = await SpeechTranscriber.supportedLocales
        return AppleSpeechEngine.resolveLocale(languageCode: code, in: supported)
    }

    /// A transcriber for the saved default language, or nil when the
    /// language has no preview. Nothing has started yet.
    public static func make(forLanguageSetting setting: String) async -> LiveTranscriber? {
        guard let locale = await locale(forLanguageSetting: setting) else {
            log.info("no live preview for language setting \(setting, privacy: .public)")
            return nil
        }
        log.info("live preview locale \(locale.identifier, privacy: .public) for setting \(setting, privacy: .public)")
        let name = Locale.current.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "")
            ?? locale.identifier
        return LiveTranscriber(locale: locale, languageName: name.localizedCapitalized)
    }

    // MARK: - Lifecycle

    /// Installs assets if needed and starts listening. Returns when the
    /// analyzer is running or has failed; the capture may feed audio from the
    /// moment this is called, since buffers before the start are dropped.
    public func start() async {
        do {
            let status = await AssetInventory.status(forModules: [transcriber])
            Self.log.info("assets \(String(describing: status), privacy: .public) for \(self.locale.identifier, privacy: .public)")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Self.log.info("installing recognizer assets")
                try await request.downloadAndInstall()
                Self.log.info("recognizer assets installed")
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
                bufferingPolicy: .bufferingNewest(64))
            let alreadyFinished = lock.withLock {
                self.analyzerFormat = format
                self.continuation = continuation
                self.analyzer = analyzer
                return finished
            }
            guard !alreadyFinished else {
                continuation.finish()
                return
            }
            collector = Task { [weak self] in
                await self?.collect()
            }
            try await analyzer.start(inputSequence: stream)
            Self.log.info("listening")
            await publish(status: .listening)
        } catch {
            Self.log.error("live preview failed to start: \(error.localizedDescription, privacy: .public)")
            await publish(status: .failed(Self.describe(error)))
        }
    }

    private static let log = Logger(subsystem: "com.shpala.Longhand", category: "live-preview")

    /// From the audio thread. Converts to the analyzer's format and queues
    /// the buffer. Cheap when nothing is listening.
    public func feed(_ buffer: AVAudioPCMBuffer) {
        let route: (AsyncStream<AnalyzerInput>.Continuation, AVAudioFormat, AVAudioConverter)? = lock.withLock {
            guard let continuation, let analyzerFormat, !suspended, !finished else { return nil }
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
            }
            guard let converter else { return nil }
            return (continuation, analyzerFormat, converter)
        }
        guard let (continuation, format, converter) = route,
              let converted = Self.convert(buffer, with: converter, to: format) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    /// Stops feeding without stopping the analyzer: the app went to the
    /// background, where sustained recognition is not worth the battery, or
    /// the sheet asked for quiet. Words already settled stay.
    public func setSuspended(_ value: Bool) {
        let (changed, finished) = lock.withLock {
            let changed = suspended != value
            suspended = value
            return (changed, self.finished)
        }
        guard changed, !finished else { return }
        Task { await publish(status: value ? .suspended : .listening) }
    }

    /// Ends the stream and lets the recognizer settle what it heard. Idempotent.
    public func finish() async {
        let (wasFinished, continuation, analyzer) = lock.withLock {
            let wasFinished = finished
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            return (wasFinished, continuation, self.analyzer)
        }
        guard !wasFinished else { return }
        continuation?.finish()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        _ = await collector?.value
        let final = lock.withLock {
            text.settle()
            return text
        }
        await MainActor.run {
            output.apply(final)
            output.setStatus(.stopped)
        }
    }

    /// Stops at once without waiting for the recognizer: the take was discarded.
    public func cancel() {
        let (continuation, analyzer) = lock.withLock {
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            return (continuation, self.analyzer)
        }
        continuation?.finish()
        collector?.cancel()
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    // MARK: - Results

    private func collect() async {
        var lastPublish = ContinuousClock.now
        do {
            for try await result in transcriber.results {
                try Task.checkCancellation()
                let words = String(result.text.characters)
                let isFinal = result.isFinal
                let snapshot = lock.withLock {
                    text.apply(words, isFinal: isFinal)
                    if isFinal { text.trimConfirmed(toLastWords: Self.keptWords) }
                    return text
                }
                // Volatile results can come many times a second; the sheet
                // does not need them that often, and a view redrawing that
                // fast starves the accessibility tree.
                let now = ContinuousClock.now
                if isFinal || now - lastPublish >= Self.publishInterval {
                    lastPublish = now
                    await MainActor.run { output.apply(snapshot) }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            await publish(status: .failed(Self.describe(error)))
        }
    }

    private static var publishInterval: Duration {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--uitest-") }
            ? .milliseconds(1000) : .milliseconds(300)
    }

    private func publish(status: LiveTranscript.Status) async {
        await MainActor.run { output.setStatus(status) }
    }

    private static func describe(_ error: Error) -> String {
        "Live preview isn't available (\(error.localizedDescription))."
    }

    // MARK: - Audio

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}
