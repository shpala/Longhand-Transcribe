import Foundation
import LonghandKit

/// User-selectable Whisper weights (§6.1). Turbo is the compressed default;
/// `large` is the non-distilled large-v3: bigger download, slower decode, same
/// contract. Smallest first, which is the order Settings draws them in.
public nonisolated enum WhisperModelVariant: String, CaseIterable, Sendable {
    case base
    case small
    case turbo
    case turboSpeedBuild
    case large

    public var modelName: String {
        switch self {
        case .base: "openai_whisper-base"
        case .small: "openai_whisper-small"
        case .turbo: "openai_whisper-large-v3-v20240930_626MB"
        case .turboSpeedBuild: "openai_whisper-large-v3-v20240930_turbo_632MB"
        case .large: "openai_whisper-large-v3_947MB"
        }
    }

    public var modelIdentifier: String {
        switch self {
        case .base: "whisperkit/base"
        case .small: "whisperkit/small"
        case .turbo: "whisperkit/large-v3-v20240930_626MB"
        case .turboSpeedBuild: "whisperkit/large-v3-v20240930_turbo_632MB"
        case .large: "whisperkit/large-v3_947MB"
        }
    }

    /// Named before anything is fetched (§4.2.3(ii)). The two large variants
    /// carry their size in the vendor's model name; `base` and `small` are
    /// summed file sizes from `argmaxinc/whisperkit-coreml`, not estimates.
    public var approximateBytes: Int64 {
        switch self {
        case .base: 146_549_212
        case .small: 484_489_287
        case .turbo: 626 * 1_000_000
        case .turboSpeedBuild: 637_947_269
        case .large: 947 * 1_000_000
        }
    }

    public var displayName: String {
        switch self {
        case .base: String(localized: "Base: fastest, least accurate")
        case .small: String(localized: "Small")
        case .turbo: String(localized: "Fast")
        case .turboSpeedBuild: String(localized: "Fast: speed build")
        case .large: String(localized: "Maximum accuracy")
        }
    }

    /// Not phrased as "smaller is faster": `turbo` is a large-v3 distillation
    /// with four decoder layers where `small` has twelve, and Whisper's cost is
    /// per decoded token, so `small` may well lose to `turbo`.
    public var speedNote: String {
        switch self {
        case .base: String(localized: "6 decoder layers. Much faster; expect noticeably worse accuracy, especially outside English.")
        case .small: String(localized: "12 decoder layers, more than Fast despite the smaller download. May not be quicker; compare the timings.")
        case .turbo: String(localized: "4 decoder layers, so it decodes quickly for its size. The default, and Argmax's recommendation for iOS.")
        case .turboSpeedBuild: String(localized: "The same model at the same size, built for speed and with a prefill decoder. Argmax recommends this build on Mac, not iPhone, so compare the timings before trusting it here.")
        case .large: String(localized: "32 decoder layers. The most accurate and by far the slowest.")
        }
    }

    /// The variants Settings may offer, on every platform. The enum keeps every
    /// build the engine can load, since a job's `models` block records what
    /// transcribed it and re-running has to stay reproducible; only these two
    /// are worth offering as a choice.
    ///
    /// The iPhone narrowed this to `turbo` alone for a while. The reasoning was
    /// sound (a Mac has thermal headroom a phone does not) and the remedy was
    /// not: it removed the owner's ability to trade speed for accuracy on the
    /// device that records most of the audio. The cost is stated on the
    /// Settings screen instead.
    public static let selectable: [WhisperModelVariant] = [.turbo, .large]

    public static let defaultsKey = "whisperModelVariant"

    /// The persisted Settings choice; anything unrecognized falls back to turbo.
    public static var current: WhisperModelVariant {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(WhisperModelVariant.init(rawValue:)) ?? .turbo
    }
}

#if canImport(WhisperKit)
import WhisperKit

/// WhisperKit adapter (§6): selected by §4.2 routing for languages Apple's
/// engine does not cover. Weights download once from Argmax's hosting on first
/// use, which is asset acquisition, not audio egress (§14.2).
public nonisolated final class WhisperKitEngine: SpeechTranscribing {

    public static let engineID = "whisperkit"
    public let variant: WhisperModelVariant
    public var modelIdentifier: String { variant.modelIdentifier }

    public init(variant: WhisperModelVariant = .turbo) {
        self.variant = variant
    }

    /// Long-file threshold above which incremental loading is mandatory (§6.2).
    public static let incrementalLoadingThreshold: TimeInterval = 600

    private static let whisperLanguageCodes = Set(Constants.languages.values)

    public func supports(language: Locale.Language) -> Bool {
        guard let code = language.languageCode?.identifier else { return false }
        return Self.whisperLanguageCodes.contains(code)
    }

    /// With no pinned language, Whisper re-detects per decoding window
    /// (~30 s granularity).
    public var supportsLanguageAutoDetection: Bool { true }

    /// What the §4.2.3(ii) consent prompt names, until the weights are on disk.
    public var pendingDownloadBytes: Int64? {
        modelLikelyDownloaded() ? nil : variant.approximateBytes
    }

    /// Loads the weights, fetching them first when there is nothing usable on
    /// disk.
    ///
    /// `download: false` on the local path is the whole point. WhisperKit will
    /// otherwise consult the hub and re-fetch from inside what this stage calls
    /// "Loading speech model…", so a three-minute download reports as a load
    /// and §14.2 stops meaning anything. A tree that is present but will not
    /// load is purged and re-asked for rather than silently re-fetched: a
    /// repair costs the same 626 MB the §4.2.3(ii) gate exists to disclose.
    private func loadModel(progress: @escaping ProgressSink) async throws -> WhisperKit {
        ModelStaging.excludeFromBackup()
        guard modelLikelyDownloaded() else {
            return try await downloadAndLoadModel(progress: progress)
        }
        // Its own stage: on a short take, staging the model onto the ANE can
        // outlast the decoding it enables.
        let isFirstLoad = !Self.hasLoadedBefore(variant)
        progress(PipelineProgress(stage: .loadingModel, fraction: 0, isFirstModelLoad: isFirstLoad))
        do {
            let whisper = try await WhisperKit(model: variant.modelName,
                                               modelFolder: Self.modelFolder(for: variant).path,
                                               verbose: false, logLevel: .error,
                                               prewarm: false, load: true, download: false)
            Self.markLoaded(variant)
            // Safe here and only here: the weights just loaded, so whatever is
            // still sitting in the vendor's staging area is abandoned rather
            // than a fetch in flight.
            ModelStaging.sweep(in: Self.modelFolder(for: variant).deletingLastPathComponent())
            return whisper
        } catch {
            // Purging is what stops the loop: the presence check answers
            // "absent" on the next run, so consent is asked once and the
            // refetch is a real one rather than a no-op over the same tree.
            Self.asset(for: variant).purge()
            throw LonghandError.modelDownloadRequired(
                asset: "The \(Self.engineID) speech model (the copy on this device could not be loaded)",
                bytes: variant.approximateBytes)
        }
    }

    private func downloadAndLoadModel(progress: @escaping ProgressSink) async throws -> WhisperKit {
        do {
            // §14.2: its own stage with a real number, so the first run does
            // not read as a hang.
            progress(PipelineProgress(stage: .downloadingModel, fraction: 0, isDeterminate: true))
            let reported = ThrottledFraction()
            let folder = try await WhisperKit.download(variant: variant.modelName) { downloadProgress in
                if let fraction = reported.accept(downloadProgress.fractionCompleted) {
                    // On every update, not just the first: the row reads the
                    // flag off the latest progress.
                    progress(PipelineProgress(stage: .downloadingModel, fraction: fraction,
                                              isDeterminate: true))
                }
            }
            progress(PipelineProgress(stage: .loadingModel, fraction: 0,
                                      isFirstModelLoad: !Self.hasLoadedBefore(variant)))
            let whisper = try await WhisperKit(model: variant.modelName,
                                               modelFolder: folder.path,
                                               verbose: false, logLevel: .error,
                                               prewarm: false, load: true, download: false)
            Self.markLoaded(variant)
            // Safe here and only here: the weights just loaded, so whatever is
            // still sitting in the vendor's staging area is abandoned rather
            // than a fetch in flight.
            ModelStaging.sweep(in: Self.modelFolder(for: variant).deletingLastPathComponent())
            return whisper
        } catch {
            throw LonghandError.modelAssetMissing(
                asset: "WhisperKit \(variant.modelName) (load/download failed: \(error.localizedDescription))")
        }
    }

    public func transcribe(_ input: AudioAsset, language: Locale.Language?,
                    progress: @escaping ProgressSink) async throws -> ASRResult {
        // A fresh instance per job keeps no models resident between stages (§7.3).
        let whisper = try await loadModel(progress: progress)

        let languageCode = language?.languageCode?.identifier
        // detectLanguage defaults to OFF when the prefill prompt is on, which
        // silently decodes unpinned audio as English. VAD chunking splits at
        // silences, giving each chunk its own detection (§6.2).
        let decodeOptions = DecodingOptions(task: .transcribe,
                                            language: languageCode,
                                            detectLanguage: languageCode == nil ? true : nil,
                                            wordTimestamps: true,
                                            chunkingStrategy: .vad)
        let audioInputOptions: AudioInputOptions? =
            input.duration > Self.incrementalLoadingThreshold
                ? AudioInputOptions(audioLoadingMode: .incremental(
                    chunkDurationSeconds: AudioInputOptions.AudioLoadingMode.defaultChunkDurationSeconds,
                    maxBufferedChunks: AudioInputOptions.AudioLoadingMode.defaultMaxBufferedChunks))
                : nil

        let duration = input.duration
        // VAD windows decode concurrently and each reports its own absolute
        // end time, so segment ends arrive out of order and can move backwards.
        let furthest = ThrottledFraction.HighWaterMark()
        whisper.segmentDiscoveryCallback = { segments in
            guard duration > 0, let last = segments.last else { return }
            let reached = furthest.advance(to: min(duration, Double(last.end)))
            progress(PipelineProgress(stage: .transcribing,
                                      fraction: min(1.0, reached / duration),
                                      isDeterminate: true,
                                      processedSeconds: reached,
                                      totalSeconds: duration))
        }

        // Returning false from the per-token callback is the only hook
        // WhisperKit offers for stopping a decoding window early. The callback
        // cannot read `Task.isCancelled`: it runs in a `Task.detached` whose
        // cancellation state is its own and always false.
        let stopping = CancellationFlag()
        let results = try await withTaskCancellationHandler {
            try await whisper.transcribe(audioPath: input.url.path,
                                         audioInputOptions: audioInputOptions,
                                         decodeOptions: decodeOptions,
                                         callback: { _ in !stopping.isSet })
        } onCancel: {
            stopping.set()
        }
        // Early stopping returns what was decoded so far as a normal result,
        // and checkpointing that would record a truncated transcript as the
        // whole recording. A cancel is an interruption (§10).
        try Task.checkCancellation()

        var segments: [ASRSegment] = []
        var index = 0
        for result in results {
            for segment in result.segments {
                let text = Self.stripSpecialTokens(segment.text)
                let words: [ASRWord] = (segment.words ?? []).compactMap { timing in
                    let wordText = timing.word.trimmingCharacters(in: .whitespaces)
                    guard !wordText.isEmpty else { return nil }
                    return ASRWord(text: wordText,
                                   start: TimeInterval(timing.start),
                                   end: TimeInterval(timing.end),
                                   avgLogprob: Double(log(max(timing.probability, 1e-9))))
                }
                guard !text.isEmpty || !words.isEmpty else { continue }
                segments.append(ASRSegment(id: index,
                                           start: TimeInterval(segment.start),
                                           end: TimeInterval(segment.end),
                                           text: text,
                                           words: words,
                                           avgLogprob: Double(segment.avgLogprob)))
                index += 1
            }
        }
        progress(PipelineProgress(stage: .transcribing, fraction: 1.0))
        // Each window carries its own detected language, and §13.1's single
        // field cannot hold a set, so more than one records as "multi".
        let resolvedLanguage: String
        if let languageCode {
            resolvedLanguage = languageCode
        } else {
            let detected = Set(results.map(\.language))
            resolvedLanguage = detected.count == 1 ? (detected.first ?? "und")
                             : detected.isEmpty ? "und" : "multi"
        }
        return ASRResult(language: resolvedLanguage,
                         engine: Self.engineID,
                         modelIdentifier: modelIdentifier,
                         segments: segments)
    }

    /// One-way "the caller gave up" flag, readable from WhisperKit's own
    /// detached callback task.
    final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        func set() { lock.lock(); stopped = true; lock.unlock() }
    }

    /// Reports only meaningful changes: download callbacks fire far more often
    /// than the UI needs, and every report hops to the main actor.
    public final class ThrottledFraction: @unchecked Sendable {
        private let lock = NSLock()
        private var last: Double = -1
        func accept(_ fraction: Double) -> Double? {
            lock.lock()
            defer { lock.unlock() }
            guard fraction - last >= 0.01 || fraction >= 1 else { return nil }
            last = fraction
            return fraction
        }

        /// Monotonic ratchet for out-of-order reports.
        public final class HighWaterMark: @unchecked Sendable {
            private let lock = NSLock()
            private var highest: Double = 0
            public init() {}
            public func advance(to value: Double) -> Double {
                lock.lock()
                defer { lock.unlock() }
                highest = max(highest, value)
                return highest
            }
        }
    }

    /// Whether these weights have been loaded on this device before.
    ///
    /// Core ML compiles a model for the device on first load and caches the
    /// result, so the first load costs minutes and the rest cost seconds. The
    /// flag is what lets the UI say "one-time" truthfully rather than either
    /// always or never. A cleared cache makes this optimistic, which is the
    /// harmless direction: the label understates a wait instead of promising a
    /// one-time cost that recurs.
    static func loadedKey(_ variant: WhisperModelVariant) -> String {
        "whisperModelLoaded." + variant.modelName
    }

    static func hasLoadedBefore(_ variant: WhisperModelVariant) -> Bool {
        UserDefaults.standard.bool(forKey: loadedKey(variant))
    }

    static func markLoaded(_ variant: WhisperModelVariant) {
        UserDefaults.standard.set(true, forKey: loadedKey(variant))
    }

    /// Where WhisperKit keeps a downloaded variant.
    public static func modelFolder(for variant: WhisperModelVariant) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(variant.modelName)")
    }

    /// The three compiled bundles a usable variant has, verified against a real
    /// device download. All three are loaded at inference time, so a check that
    /// omits one calls a download complete that WhisperKit will reject.
    static let requiredComponents = ["MelSpectrogram.mlmodelc",
                                     "AudioEncoder.mlmodelc",
                                     "TextDecoder.mlmodelc"]

    /// The tree on disk, and the rule for whether it will load.
    public static func asset(for variant: WhisperModelVariant) -> ModelAsset {
        ModelAsset(name: "WhisperKit \(variant.modelName)",
                   root: modelFolder(for: variant),
                   components: requiredComponents)
    }

    /// Every required component present and loadable under `root`, exposed for
    /// the tests that stage a tree in a temporary directory.
    static func modelsPresent(in root: URL) -> Bool {
        ModelAsset.isPresent(in: root, components: requiredComponents)
    }

    public static func isDownloaded(_ variant: WhisperModelVariant) -> Bool {
        asset(for: variant).isPresent
    }

    /// Bytes on disk for a variant, for the Settings storage line.
    public static func downloadedBytes(for variant: WhisperModelVariant) -> Int64 {
        asset(for: variant).bytesOnDisk
    }

    /// Removes a downloaded variant and reports the bytes reclaimed.
    ///
    /// Three things go, not one. The tree itself is the 626 MB or 947 MB
    /// anyone came here for. The vendor's staging area beside it can hold a
    /// partial payload from an interrupted fetch, which `ModelStaging` counts
    /// but which would otherwise survive a delete and make the freed figure a
    /// lie. And the loaded flag has to be cleared, because it is what lets the
    /// download sheet promise a one-time compile: a re-downloaded model is new
    /// files, so Core ML compiles again, and a stale `true` would understate
    /// the wait on exactly the run where it is longest.
    ///
    /// Callers must not delete a variant a running job is using. Nothing here
    /// can check that, since the engine does not know about jobs; the UI gates
    /// on `runningJobs` instead.
    @discardableResult
    public static func delete(_ variant: WhisperModelVariant) -> Int64 {
        let asset = asset(for: variant)
        let reclaimed = asset.bytesOnDisk
        asset.purge()
        let staged = ModelStaging.sweep(in: modelFolder(for: variant).deletingLastPathComponent())
        UserDefaults.standard.removeObject(forKey: loadedKey(variant))
        return reclaimed + staged
    }

    /// What deleting a variant would free, so the confirmation can name a
    /// number instead of asking someone to trust one.
    public static func reclaimableBytes(for variant: WhisperModelVariant) -> Int64 {
        guard isDownloaded(variant) else { return 0 }
        return downloadedBytes(for: variant)
    }

    public func modelLikelyDownloaded() -> Bool {
        Self.isDownloaded(variant)
    }

    /// Fetches a variant ahead of any job, so the first recording is not the
    /// moment someone discovers there is a 626 MB download (§13.3, §14.2).
    public static func prefetch(_ variant: WhisperModelVariant,
                                progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !isDownloaded(variant) else { return }
        let reported = ThrottledFraction()
        do {
            _ = try await WhisperKit.download(variant: variant.modelName) { downloadProgress in
                if let fraction = reported.accept(downloadProgress.fractionCompleted) {
                    progress(fraction)
                }
            }
            progress(1)
        } catch {
            throw LonghandError.modelAssetMissing(
                asset: "WhisperKit \(variant.modelName) (download failed: \(error.localizedDescription))")
        }
    }

    public static func stripSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#else

/// Placeholder when the WhisperKit package is absent: declares no coverage, so
/// §4.2 routing never selects it and the router reports engineUnavailable (§17).
public nonisolated final class WhisperKitEngine: SpeechTranscribing {
    public static let engineID = "whisperkit"
    public let variant: WhisperModelVariant
    public var modelIdentifier: String { variant.modelIdentifier }

    public init(variant: WhisperModelVariant = .turbo) {
        self.variant = variant
    }

    public func supports(language: Locale.Language) -> Bool { false }
    public var supportsLanguageAutoDetection: Bool { false }

    public func transcribe(_ input: AudioAsset, language: Locale.Language?,
                    progress: @escaping ProgressSink) async throws -> ASRResult {
        throw LonghandError.engineUnavailable(engine: Self.engineID,
                                              language: language?.languageCode?.identifier ?? "und")
    }
}
#endif
