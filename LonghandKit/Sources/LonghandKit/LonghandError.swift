import Foundation

/// Failure taxonomy per §17. Errors are specific and actionable; none of them
/// may silently degrade output.
public enum LonghandError: Error, Equatable {
    /// Validation rejected the media before any neural inference, naming the
    /// detected format. `rawPCMCandidate` signals the UI to offer the explicit
    /// raw-PCM confirmation path (§5.5).
    case unsupportedMedia(detected: String, rawPCMCandidate: Bool)
    case decodeFailed(reason: String)
    case modelAssetMissing(asset: String)
    /// The engine needs to fetch weights before it can run, and the user has
    /// not agreed to the download yet. App Store guideline 4.2.3(ii) requires
    /// the size to be disclosed and consent taken first; carrying the byte
    /// count in the error is what lets the UI name it.
    case modelDownloadRequired(asset: String, bytes: Int64)

    /// Errors that are really questions: the pipeline stopped to ask
    /// something only a person can answer, with every checkpoint intact. They
    /// travel as errors because that is how a stage aborts, but a job holding
    /// one has not failed. It is waiting, and calling it "Couldn't
    /// transcribe" is the same class of lie as a silent degradation (§17).
    public var isAwaitingAnswer: Bool {
        switch self {
        case .modelDownloadRequired: true
        case let .unsupportedMedia(_, rawPCMCandidate): rawPCMCandidate
        default: false
        }
    }
    case modelAssetIntegrity(asset: String)
    case insufficientDisk(requiredBytes: Int64, availableBytes: Int64)
    case engineUnavailable(engine: String, language: String)
    case checkpointCorrupt(stage: String)
    case invalidStateTransition(from: JobState, to: JobState)
    case cancelled
}

extension LonghandError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedMedia(detected, rawPCM):
            var msg = "Unsupported media format: \(detected)."
            if rawPCM {
                msg += " If you know this is raw 16 kHz mono PCM, you can confirm that format to import it."
            }
            return msg
        case let .decodeFailed(reason):
            return "Audio could not be decoded: \(reason)"
        case let .modelAssetMissing(asset):
            return "Required model asset is not installed: \(asset). Download it to continue."
        case let .modelDownloadRequired(asset, bytes):
            let f = ByteCountFormatter()
            return "\(asset) needs a one-time \(f.string(fromByteCount: bytes)) download before it can run."
        case let .modelAssetIntegrity(asset):
            return "Model asset failed integrity verification: \(asset). Re-download required; unverified assets are never used."
        case let .insufficientDisk(required, available):
            let f = ByteCountFormatter()
            return "Not enough free space: \(f.string(fromByteCount: required)) required, \(f.string(fromByteCount: available)) available."
        case let .engineUnavailable(engine, language):
            return "Transcription engine \(engine) is not available for language “\(language)”."
        case let .checkpointCorrupt(stage):
            return "Checkpoint for stage \(stage) is invalid and will be recomputed."
        case let .invalidStateTransition(from, to):
            return "Invalid job state transition \(from.rawValue) → \(to.rawValue)."
        case .cancelled:
            return "The job was cancelled."
        }
    }
}
