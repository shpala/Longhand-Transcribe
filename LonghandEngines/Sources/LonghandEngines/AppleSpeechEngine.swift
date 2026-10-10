import Foundation
import Speech
import AVFoundation
import CoreMedia
import LonghandKit

/// Apple's on-device SpeechTranscriber (iOS 26) behind the SpeechTranscribing
/// protocol (§4.2). Assets are OS-managed; a one-time OS download may occur,
/// which is asset acquisition, not audio egress: the inference path stays
/// local (§14.2).
public nonisolated final class AppleSpeechEngine: SpeechTranscribing {

    public static let engineID = "apple-speechtranscriber"
    public let modelIdentifier = "apple-speechtranscriber/ios26"

    private let supportedLocales: [Locale]

    /// Capability set is loaded once; §4.2's routing decision reads it per job.
    public static func make() async -> AppleSpeechEngine {
        AppleSpeechEngine(supportedLocales: await SpeechTranscriber.supportedLocales)
    }

    private init(supportedLocales: [Locale]) {
        self.supportedLocales = supportedLocales
    }

    public func supports(language: Locale.Language) -> Bool {
        guard let code = language.languageCode?.identifier else { return false }
        return supportedLocales.contains { $0.language.languageCode?.identifier == code }
    }

    /// Single-locale by design; mixed-language jobs route to WhisperKit (§4.2).
    public var supportsLanguageAutoDetection: Bool { false }

    public func transcribe(_ input: AudioAsset, language: Locale.Language?,
                    progress: @escaping ProgressSink) async throws -> ASRResult {
        let locale = try resolveLocale(for: language)
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])

        // OS-managed asset download; refuses to run without assets rather than
        // degrading (§13.3 integrity posture is Apple's to enforce here).
        do {
            await Self.makeRoom(for: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                // Distinguish the one-time download from transcription so a
                // first run doesn't read as a hang (§14.2 honesty, in the UI),
                // with real fractions polled from the OS request.
                progress(PipelineProgress(stage: .downloadingModel, fraction: 0, isDeterminate: true))
                let requestProgress = request.progress
                let poller = Task {
                    while !Task.isCancelled {
                        progress(PipelineProgress(stage: .downloadingModel,
                                                  fraction: requestProgress.fractionCompleted,
                                                  isDeterminate: true))
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                }
                defer { poller.cancel() }
                try await request.downloadAndInstall()
            }
        } catch {
            throw LonghandError.modelAssetMissing(
                asset: "Apple speech model for \(locale.identifier) (OS-managed download failed: \(error.localizedDescription))")
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: input.url)
        } catch {
            throw LonghandError.decodeFailed(reason: "normalized audio unreadable: \(error.localizedDescription)")
        }

        let duration = input.duration
        let collector = Task<[ASRSegment], any Error> {
            var segments: [ASRSegment] = []
            var segmentID = 0
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let text = String(result.text.characters)
                var words: [ASRWord] = []
                for run in result.text.runs {
                    guard let timeRange = run.audioTimeRange else { continue }
                    let runText = String(result.text[run.range].characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !runText.isEmpty else { continue }
                    words.append(ASRWord(text: runText,
                                         start: timeRange.start.seconds,
                                         end: timeRange.end.seconds,
                                         avgLogprob: nil))
                }
                guard !words.isEmpty || !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let start = words.first?.start ?? 0
                let end = words.last?.end ?? start
                segments.append(ASRSegment(id: segmentID, start: start, end: end,
                                           text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                           words: words))
                segmentID += 1
                if duration > 0 {
                    progress(PipelineProgress(stage: .transcribing, fraction: min(1.0, end / duration)))
                }
            }
            return segments
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch let error as LonghandError {
            // Finished on every path: an analyzer left mid-flight keeps its
            // locale allocation, and the framework allows five per process.
            // A job retried a few times after an interruption ran out.
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw LonghandError.decodeFailed(reason: "SpeechAnalyzer failed for \(locale.identifier): \(error.localizedDescription)")
        }

        let segments = try await collector.value
        progress(PipelineProgress(stage: .transcribing, fraction: 1.0))
        return ASRResult(language: locale.language.languageCode?.identifier ?? "und",
                         engine: Self.engineID,
                         modelIdentifier: modelIdentifier,
                         segments: segments)
    }

    /// SpeechTranscriber accepts only locales from its supported set. Passing
    /// the raw device locale (e.g. en_IL) is rejected at asset reservation.
    /// Resolve by language code against the supported set, preferring the
    /// device's region when Apple offers it.
    private func resolveLocale(for language: Locale.Language?) throws -> Locale {
        let target = language ?? Locale.current.language
        guard let code = target.languageCode?.identifier else {
            throw LonghandError.engineUnavailable(engine: Self.engineID, language: "und")
        }
        guard let locale = Self.resolveLocale(languageCode: code, in: supportedLocales) else {
            // Covers both an unsupported language and environments (like
            // simulators) that report no locales at all.
            throw LonghandError.engineUnavailable(engine: Self.engineID, language: code)
        }
        return locale
    }

    /// The framework keeps a per-app list of reserved locales, five at most,
    /// and refuses to install assets for a sixth. This app needs one or two.
    /// Anything else reserved is released before a new one is asked for,
    /// which costs nothing but a re-reservation if that language comes back.
    static func makeRoom(for locale: Locale) async {
        let reserved = await AssetInventory.reservedLocales
        guard reserved.count >= AssetInventory.maximumReservedLocales,
              !reserved.contains(locale) else { return }
        for other in reserved where other != locale {
            _ = await AssetInventory.release(reservedLocale: other)
        }
    }

    /// The supported locale for a language code, preferring the device's own
    /// region when Apple offers it. Shared with the live preview, which must
    /// pick the same locale the final pass will.
    static func resolveLocale(languageCode code: String, in supported: [Locale]) -> Locale? {
        let candidates = supported.filter { $0.language.languageCode?.identifier == code }
        guard !candidates.isEmpty else { return nil }
        if let region = Locale.current.region?.identifier,
           let regionMatch = candidates.first(where: { $0.region?.identifier == region }) {
            return regionMatch
        }
        return candidates[0]
    }
}
