import Foundation
import LonghandKit

/// Turning a deliberately recorded clip into an enrollable voice embedding
/// (§9.2, §9.3 known-self mode).
///
/// The point of this path is the cold start. Enrolling from a transcript needs
/// a recording that already exists and has already been processed, so the very
/// first two-person call cannot label "Me" no matter how obvious it is. One
/// clip recorded up front fixes that, and nothing else about identification
/// changes: `SpeakerMatcher` already generalises over however many people are
/// enrolled.
///
/// The embedding is produced by the same diarizer the pipeline uses, over audio
/// normalised the same way (§5.4), because an embedding made by any other route
/// would not be comparable with the centroids it is later matched against.
public nonisolated enum VoiceEnrollment {

    /// Long enough that the embedder has something to work with. Community-1
    /// will answer for less, but a centroid over a couple of seconds of speech
    /// is noise wearing a voice's clothes, and this is the one sample that
    /// decides whether the first call says "Me" or gets it wrong.
    public static let minimumSpeechSeconds: Double = 6

    public struct Enrollment: Sendable {
        public let embedding: [Float]
        public let modelIdentifier: String
        /// Speech actually found, which is not the clip's length: someone who
        /// records twenty seconds and talks for four should be told so.
        public let speechSeconds: Double
    }

    public enum Failure: LocalizedError, Equatable {
        case notEnoughSpeech(found: Double, needed: Double)
        case moreThanOneVoice
        case noEmbedding

        public var errorDescription: String? {
            switch self {
            case let .notEnoughSpeech(found, needed):
                let f = String(format: "%.0f", found), n = String(format: "%.0f", needed)
                return "Only \(f) second\(found == 1 ? "" : "s") of speech was found, and \(n) are needed. Try again and keep talking until the timer stops."
            case .moreThanOneVoice:
                return "More than one voice was heard. Record somewhere quieter, with nobody else speaking."
            case .noEmbedding:
                return "This recording produced no voice signature. Try again, a little closer to the microphone."
            }
        }
    }

    /// Produces an embedding from a clip, and deletes every derived copy of the
    /// audio before returning.
    ///
    /// §14.1 requires temporary enrollment clips to go immediately after the
    /// embedding exists. The normalised copy is made here so it is deleted
    /// here; the caller's own recording is the caller's to remove, which the
    /// shells do in their `defer`.
    /// `diarizer` is nil in the app and injected by the tests. It cannot
    /// default to `CommunityOneDiarizer()` in the signature: its initialiser is
    /// internal, and making it public to satisfy a default argument would widen
    /// the engine's surface for the convenience of one call site.
    public static func embed(clipURL: URL,
                             diarizer: (any SpeakerDiarizer)? = nil,
                             progress: @escaping ProgressSink = { _ in }) async throws -> Enrollment {
        let diarizer = diarizer ?? CommunityOneDiarizer()
        let normalized = FileManager.default.temporaryDirectory
            .appendingPathComponent("enroll-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: normalized) }

        let (asset, _) = try AudioNormalizer.normalize(sourceURL: clipURL, destinationURL: normalized)
        let result = try await diarizer.diarize(asset, expectedSpeakers: 1, progress: progress)

        // Speech per cluster, so "how much did they say" and "was anyone else
        // here" are the same question asked once.
        var secondsByCluster: [String: Double] = [:]
        for interval in result.intervals {
            secondsByCluster[interval.speaker, default: 0] += max(0, interval.end - interval.start)
        }
        let ranked = secondsByCluster.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }
        guard let dominant = ranked.first else {
            throw Failure.notEnoughSpeech(found: 0, needed: minimumSpeechSeconds)
        }

        // A second voice with real airtime means the clip is not what it claims
        // to be. A brief spurious cluster is normal and is not worth refusing
        // over, so the bar is a fifth of the main speaker rather than zero.
        if let runnerUp = ranked.dropFirst().first,
           runnerUp.value > dominant.value * 0.2 {
            throw Failure.moreThanOneVoice
        }
        guard dominant.value >= minimumSpeechSeconds else {
            throw Failure.notEnoughSpeech(found: dominant.value, needed: minimumSpeechSeconds)
        }
        guard let embedding = result.centroids?[dominant.key], !embedding.isEmpty else {
            throw Failure.noEmbedding
        }

        return Enrollment(embedding: embedding,
                          modelIdentifier: result.modelIdentifier,
                          speechSeconds: dominant.value)
    }
}
