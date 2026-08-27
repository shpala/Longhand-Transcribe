import Foundation

/// §18.2's calibration, run against the labels the library already holds.
///
/// `SpeakerMatcher.Config`'s floor and margin were set from a handful of
/// on-device readings and have carried a note ever since saying the proper
/// source is a calibration test with true speaker pairs. Those pairs exist: a
/// cluster whose name the user *confirmed* is a labelled voice, and its
/// centroid is the embedding the matcher would compare. Two jobs naming the
/// same person give a same-speaker pair; two names give a different-speaker
/// pair.
///
/// Only `confirmedByUser` names count. A name the matcher itself proposed is
/// the very claim being calibrated, and taking it as ground truth would ask the
/// matcher to mark its own work (§13.1: the user said, the model thinks).
public enum SpeakerCalibration {

    public struct LabelledVoice: Sendable, Equatable {
        public let jobID: String
        public let person: String
        public let cluster: String
        public let modelIdentifier: String
        public let embedding: [Float]

        public init(jobID: String, person: String, cluster: String,
                    modelIdentifier: String, embedding: [Float]) {
            self.jobID = jobID
            self.person = person
            self.cluster = cluster
            self.modelIdentifier = modelIdentifier
            self.embedding = embedding
        }
    }

    public struct Pair: Sendable, Equatable {
        public let a: LabelledVoice
        public let b: LabelledVoice
        public let similarity: Double
        public var isSameSpeaker: Bool { a.person == b.person }
        /// Both voices come from one recording, so the pair says nothing about
        /// how a voice travels between sittings, which is what the floor
        /// guards. Kept and labelled rather than dropped.
        public var isWithinOneRecording: Bool { a.jobID == b.jobID }
    }

    public struct Distribution: Sendable, Equatable {
        public let count: Int
        public let lowest: Double
        public let highest: Double
        public let mean: Double

        init?(_ values: [Double]) {
            guard !values.isEmpty else { return nil }
            count = values.count
            lowest = values.min() ?? 0
            highest = values.max() ?? 0
            mean = values.reduce(0, +) / Double(values.count)
        }
    }

    /// Every cluster in a job whose name the user confirmed, paired with the
    /// centroid the matcher would have compared.
    public static func labelledVoices(inJobAt root: URL) -> [LabelledVoice] {
        let files = JobFiles(root: root)
        guard let transcript = (try? AtomicFile.readJSON(Transcript.self,
                                                         from: files.transcriptJSON, stage: "COMPLETE")) ?? nil,
              let diarization = (try? AtomicFile.readJSON(DiarizationResult.self,
                                                          from: files.diarization, stage: "DIARIZED")) ?? nil,
              let centroids = diarization.centroids
        else { return [] }

        return transcript.speakers.compactMap { cluster, speaker -> LabelledVoice? in
            guard speaker.confirmedByUser == true,
                  let embedding = centroids[cluster], !embedding.isEmpty else { return nil }
            return LabelledVoice(jobID: root.lastPathComponent,
                                 person: speaker.displayName,
                                 cluster: cluster,
                                 modelIdentifier: diarization.modelIdentifier,
                                 embedding: embedding)
        }.sorted { ($0.cluster, $0.person) < ($1.cluster, $1.person) }
    }

    public static func labelledVoices(libraryAt root: URL) -> [LabelledVoice] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { labelledVoices(inJobAt: $0) }
    }

    /// Every distinct pair. Embeddings from different embedders are not
    /// comparable (§13.2), so they are never paired.
    public static func pairs(from voices: [LabelledVoice]) -> [Pair] {
        var result: [Pair] = []
        for i in voices.indices {
            for j in voices.index(after: i)..<voices.endIndex {
                guard voices[i].modelIdentifier == voices[j].modelIdentifier else { continue }
                result.append(Pair(a: voices[i], b: voices[j],
                                   similarity: SpeakerMatcher.cosineSimilarity(voices[i].embedding,
                                                                               voices[j].embedding)))
            }
        }
        return result
    }

    public struct Report: Sendable {
        public let pairs: [Pair]
        /// The same person in two different recordings, which is the only
        /// evidence that speaks to the score floor.
        public let sameSpeakerAcrossRecordings: Distribution?
        public let differentSpeakers: Distribution?
        /// A person against themselves inside one recording. Enrollment takes
        /// the cluster centroid, so this is usually exactly 1.0 and is
        /// self-similarity rather than a measurement.
        public let sameSpeakerWithinOneRecording: Distribution?

        /// What the current thresholds would do with this evidence.
        public let config: SpeakerMatcher.Config
        /// Same-speaker pairs that would clear the floor. Anything below it is
        /// a match the matcher would refuse to make.
        public let sameSpeakerAboveFloor: Int
        /// Different-speaker pairs that reach the floor, which are the ones
        /// only the margin rule then stands between and a wrong name.
        public let differentSpeakersAboveFloor: Int

        /// The gap between the worst same-speaker pair and the best
        /// different-speaker one. Positive means the floor has somewhere safe
        /// to sit; negative means no single threshold separates them.
        public var separation: Double? {
            guard let same = sameSpeakerAcrossRecordings, let different = differentSpeakers
            else { return nil }
            return same.lowest - different.highest
        }
    }

    public static func report(voices: [LabelledVoice],
                              config: SpeakerMatcher.Config = SpeakerMatcher.Config()) -> Report {
        let all = pairs(from: voices)
        let sameAcross = all.filter { $0.isSameSpeaker && !$0.isWithinOneRecording }
        let sameWithin = all.filter { $0.isSameSpeaker && $0.isWithinOneRecording }
        let different = all.filter { !$0.isSameSpeaker }
        return Report(
            pairs: all,
            sameSpeakerAcrossRecordings: Distribution(sameAcross.map(\.similarity)),
            differentSpeakers: Distribution(different.map(\.similarity)),
            sameSpeakerWithinOneRecording: Distribution(sameWithin.map(\.similarity)),
            config: config,
            sameSpeakerAboveFloor: sameAcross.filter { $0.similarity >= config.scoreFloor }.count,
            differentSpeakersAboveFloor: different.filter { $0.similarity >= config.scoreFloor }.count)
    }
}
