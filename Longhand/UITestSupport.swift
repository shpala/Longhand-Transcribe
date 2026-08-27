import Foundation
import AVFoundation
import LonghandKit
import LonghandEngines

/// UI-test scaffolding: renders known speech samples and feeds them through the
/// real import pipeline, because a speaker-to-mic acoustic loop is too lossy to
/// test ASR quality deterministically. Inert unless `--uitest-synth-import` is
/// present.
///
/// `isUITestRun` sits outside the #if DEBUG boundary because shipping view code
/// reads it to pick an animation cadence; the corpus, the renderer and the
/// library-wiping reset below have no business in a Release binary.
nonisolated enum UITestSupport {

    /// Every suite passes at least `--uitest-reset`. Slows continuously
    /// animating views to the ≥0.25 s cadence XCUITest quiescence needs.
    static var isUITestRun: Bool {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--uitest-") }
    }
}

#if DEBUG
extension UITestSupport {

    static let samples: [String: (voice: String, text: String)] = [
        "he": ("he-IL", "שלום, זוהי בדיקת תמלול. אחת, שתיים, שלוש, ארבע, חמש. אני מקליט את ההודעה הזאת בעברית."),
        "ru": ("ru-RU", "Привет, это проверка транскрипции. Один, два, три, четыре, пять. Я записываю это сообщение по-русски."),
    ]

    /// Guards the one-shot synth import.
    nonisolated(unsafe) static var didRunSynthImport = false

    /// `--uitest-park-jobs`: parks every job in the library, so the stalled-row
    /// affordances (Resume / Retry) are reachable without running a real
    /// pipeline to a failure no simulator can produce on demand.
    static func parkJobsIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--uitest-park-jobs") else { return }
        for (record, files) in JobStore.allJobs() {
            var parked = record
            // Assigned, not transitioned: the state machine has no legal edge
            // here from COMPLETE. Debug-only.
            parked.state = .interrupted
            parked.pausedByUser = true
            try? AtomicFile.writeJSON(parked, to: files.job)
        }
    }

    /// `--uitest-request-record`: makes the request Siri, a shortcut, the
    /// Action Button or the Control Center control makes, before any view
    /// exists, as a cold launch from any of them does. What the intents
    /// themselves do needs Siri, which a fresh simulator does not have.
    @MainActor
    static func requestRecordingIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("--uitest-request-record") else { return }
        AppRequests.shared.startRecording = true
    }

    /// `--uitest-synth-transcript <minutes>`: writes a COMPLETE job whose
    /// transcript is the §15.2 corpus, straight to disk. No audio and no
    /// pipeline run: an hour of real transcription is not something a UI test
    /// can wait for, and what is under test here is the list, not the pipeline.
    /// The job has no `original.*`, so the player stays unloaded and the screen
    /// falls back to its no-playback layout.
    static func seedSynthTranscriptIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--uitest-synth-transcript"), flag + 1 < args.count,
              let minutes = Double(args[flag + 1]) else { return }

        let id = UUID()
        let files = JobFiles(recordingsRoot: ImportService.recordingsRoot, jobID: id)
        let speakers: [String: Transcript.Speaker] = [
            "SPEAKER_00": .init(displayName: "Speaker 1"),
            "SPEAKER_01": .init(displayName: "Speaker 2"),
        ]
        let words = TranscriptFixture.words(minutes: minutes)
        let turns = TranscriptFixture.turns(minutes: minutes, speakerNames: speakers)
        let duration = words.last?.end ?? 0

        do {
            try files.createDirectory()
            try AtomicFile.writeJSON(MergeOutput(params: MergeParams(), words: words),
                                     to: files.mergedWords)
            try AtomicFile.writeJSON(
                Transcript(recordingID: id.uuidString, sourceHash: "uitest", duration: duration,
                           language: "en", pipelineVersion: Transcript.currentPipelineVersion,
                           models: .init(asr: "uitest-synth"), mergeParams: MergeParams().record,
                           speakers: speakers, turns: turns),
                to: files.transcriptJSON)
            try AtomicFile.writeJSON(
                JobRecord(id: id, title: "Long transcript", createdAt: Date(),
                          state: .complete, lastCheckpointState: .complete,
                          duration: duration, language: "en"),
                to: files.job)
        } catch {
            // A half-written job would show as a broken row and send the suite
            // chasing the wrong thing; an absent one fails on the first query.
            try? FileManager.default.removeItem(at: files.root)
        }
    }

    static var requestedLanguages: [String] {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--uitest-synth-import"), index + 1 < args.count else {
            return []
        }
        return args[index + 1].split(separator: ",").map(String.init)
    }

    final class WriterBox: @unchecked Sendable {
        var file: AVAudioFile?
    }

    /// "auto" produces a mixed-language file: Hebrew, enough silence to push
    /// Russian into the next 30-second decoding window, then Russian.
    static func renderSample(language: String) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("synth-\(language).caf")
        try? FileManager.default.removeItem(at: url)
        let box = WriterBox()

        if language == "auto" {
            try await appendUtterance(for: "he", to: url, box: box)
            try appendSilence(seconds: 24, box: box)
            try await appendUtterance(for: "ru", to: url, box: box)
        } else {
            try await appendUtterance(for: language, to: url, box: box)
        }
        guard box.file != nil else {
            throw LonghandError.decodeFailed(reason: "speech synthesis produced no audio")
        }
        return url
    }

    private static func appendUtterance(for language: String, to url: URL, box: WriterBox) async throws {
        guard let sample = samples[language],
              let voice = AVSpeechSynthesisVoice(language: sample.voice) else {
            throw LonghandError.engineUnavailable(engine: "uitest-synth", language: language)
        }
        let utterance = AVSpeechUtterance(string: sample.text)
        utterance.voice = voice
        utterance.rate = 0.45

        // The write callback can deliver the zero-length terminator more than
        // once, and a stale callback from a previous utterance must never touch
        // this continuation.
        final class CompletionGuard: @unchecked Sendable { var done = false }
        let completion = CompletionGuard()
        // Kept alive by the continuation closure below.
        let synthesizer = AVSpeechSynthesizer()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            synthesizer.write(utterance) { buffer in
                guard !completion.done else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    completion.done = true
                    continuation.resume()
                    return
                }
                do {
                    if box.file == nil {
                        box.file = try AVAudioFile(forWriting: url, settings: pcm.format.settings)
                    }
                    try write(pcm, to: box)
                } catch {
                    completion.done = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Voices can emit different native formats; convert to the file's
    /// processing format when they disagree.
    private static func write(_ buffer: AVAudioPCMBuffer, to box: WriterBox) throws {
        guard let file = box.file else { return }
        if buffer.format == file.processingFormat {
            try file.write(from: buffer)
            return
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: file.processingFormat),
              let converted = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(Double(buffer.frameLength)
                    * file.processingFormat.sampleRate / buffer.format.sampleRate) + 1024) else {
            throw LonghandError.decodeFailed(reason: "voice format conversion failed")
        }
        var fed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError {
            throw LonghandError.decodeFailed(reason: conversionError.localizedDescription)
        }
        if converted.frameLength > 0 {
            try file.write(from: converted)
        }
    }

    private static func appendSilence(seconds: Double, box: WriterBox) throws {
        guard let file = box.file else { return }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames   // zero-filled = silence
        try file.write(from: buffer)
    }
}

#endif
