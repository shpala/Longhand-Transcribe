import Foundation

/// Normalized audio handed to inference stages: 16 kHz mono float PCM contract (§5.4).
public struct AudioAsset: Sendable, Equatable {
    public var url: URL
    public var sampleRate: Double
    public var channelCount: Int
    public var duration: TimeInterval

    public init(url: URL, sampleRate: Double, channelCount: Int, duration: TimeInterval) {
        self.url = url
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.duration = duration
    }
}

public struct PipelineProgress: Sendable, Equatable {
    public var stage: JobStage
    /// 0...1 within the stage; UI maps to completed-duration / total-duration (§11.1).
    public var fraction: Double
    /// Whether `fraction` means anything. Transcription and diarization can
    /// say where they are; the rest take seconds and have no honest number.
    public var isDeterminate: Bool
    /// Position in the recording, when the stage knows it.
    public var processedSeconds: TimeInterval?
    public var totalSeconds: TimeInterval?
    /// This device has not loaded these weights before, so Core ML is
    /// compiling them for it. Measured at two and a half minutes on an iPhone
    /// 16 Pro Max, against seconds for every load after. A wait that long
    /// under a label saying "Loading" reads as a hang, and the honest thing to
    /// say is that it happens once.
    public var isFirstModelLoad: Bool

    public init(stage: JobStage, fraction: Double, isDeterminate: Bool = false,
                processedSeconds: TimeInterval? = nil, totalSeconds: TimeInterval? = nil,
                isFirstModelLoad: Bool = false) {
        self.stage = stage
        self.fraction = fraction
        self.isDeterminate = isDeterminate
        self.processedSeconds = processedSeconds
        self.totalSeconds = totalSeconds
        self.isFirstModelLoad = isFirstModelLoad
    }

    /// For a single bar that must not jump backwards, such as the system's
    /// background-task pill. The weighting is an ordering device, not a claim:
    /// transcription is the only stage that takes real time on a long
    /// recording. Nothing in the app shows this as a number.
    public var overallFraction: Double {
        let clamped = min(1, max(0, fraction))
        switch stage {
        case .importing: return 0
        case .preparing: return 0.02
        case .downloadingModel: return 0.02 + 0.06 * clamped
        // A real wait with no fraction to report, so it owns a slice rather
        // than sitting still inside transcription's.
        case .loadingModel: return 0.08 + 0.02 * clamped
        case .transcribing: return 0.10 + 0.80 * clamped
        case .diarizing: return 0.90 + 0.06 * clamped
        case .merging: return 0.96
        case .identifying: return 0.98
        case .exporting: return 0.99
        }
    }
}

public typealias ProgressSink = @Sendable (PipelineProgress) -> Void

/// ASR engine protocol (§16.1). Named `SpeechTranscribing` because
/// `SpeechTranscriber` collides with Apple's iOS 26 type. The capability
/// declaration makes §4.2's per-language routing data-driven.
public protocol SpeechTranscribing: Sendable {
    static var engineID: String { get }
    var modelIdentifier: String { get }
    func supports(language: Locale.Language) -> Bool
    /// True when the engine can transcribe without a pinned language,
    /// re-detecting it as the recording progresses (mixed-language jobs).
    var supportsLanguageAutoDetection: Bool { get }
    /// `language` is the declared/detected language the router selected this
    /// engine for; `nil` asks an auto-detecting engine to switch freely.
    func transcribe(_ input: AudioAsset, language: Locale.Language?,
                    progress: @escaping ProgressSink) async throws -> ASRResult
    /// Bytes this engine must download before it can run, or nil if its
    /// weights are already on disk. Drives the §4.2.3(ii) consent prompt.
    var pendingDownloadBytes: Int64? { get }
}

public extension SpeechTranscribing {
    /// Engines whose models ship with the OS have nothing to disclose.
    var pendingDownloadBytes: Int64? { nil }
}

public protocol SpeakerDiarizer: Sendable {
    static var engineID: String { get }
    var modelIdentifier: String { get }
    func diarize(_ input: AudioAsset, expectedSpeakers: Int?,
                 progress: @escaping ProgressSink) async throws -> DiarizationResult
    /// As `SpeechTranscribing.pendingDownloadBytes`. The diarizer's fetch is
    /// small but it is unconditional on first use, so it needs consent too.
    var pendingDownloadBytes: Int64? { get }
}

public extension SpeakerDiarizer {
    var pendingDownloadBytes: Int64? { nil }
}

/// A diarization cluster plus the clean (non-overlapped, §8.2) ranges that are
/// safe to embed from.
public struct SpeakerCluster: Sendable, Equatable {
    public var id: String
    public var cleanRanges: [ClosedRange<TimeInterval>]

    public init(id: String, cleanRanges: [ClosedRange<TimeInterval>]) {
        self.id = id
        self.cleanRanges = cleanRanges
    }
}

public struct IdentityMatch: Codable, Sendable, Equatable {
    public var personID: String
    public var displayName: String
    public var score: Double
    /// Gap to the runner-up. §9.3: no margin, no claim.
    public var margin: Double

    public init(personID: String, displayName: String, score: Double, margin: Double) {
        self.personID = personID
        self.displayName = displayName
        self.score = score
        self.margin = margin
    }
}

public protocol SpeakerIdentifier: Sendable {
    static var engineID: String { get }
    var modelIdentifier: String { get }
    func identify(cluster: SpeakerCluster, in audio: AudioAsset) async throws -> IdentityMatch?
}

/// Ingestion-boundary format adapter (§5.5). Adapters run in a fixed order and
/// normalize into the §5.4 PCM contract so nothing downstream knows the source
/// was unusual.
public protocol AudioSourceAdapter: Sendable {
    var adapterID: String { get }
    /// Cheap header-based claim; must not run inference or full decode.
    func canHandle(fileExtension: String, header: Data) -> Bool
    /// Decode + resample source into `destinationURL` (16 kHz mono 16-bit WAV).
    func normalize(sourceURL: URL, destinationURL: URL) async throws -> AudioAsset
}
