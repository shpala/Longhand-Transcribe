import Foundation
import Testing
@testable import LonghandKit

/// The calibration's inputs are the user's own confirmations, so the rules
/// about what counts as a label matter more than the arithmetic.
@Suite struct SpeakerCalibrationTests {

    private func vector(_ seed: Double, dimension: Int = 8) -> [Float] {
        (0..<dimension).map { Float(sin(seed + Double($0))) }
    }

    private func voice(_ person: String, job: String, cluster: String = "SPEAKER_00",
                       seed: Double, model: String = "speakerkit/pyannote-community-1")
        -> SpeakerCalibration.LabelledVoice {
        SpeakerCalibration.LabelledVoice(jobID: job, person: person, cluster: cluster,
                                         modelIdentifier: model, embedding: vector(seed))
    }

    private func writeJob(at root: URL, speakers: [String: Transcript.Speaker],
                          centroids: [String: [Float]]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = JobFiles(root: root)
        try AtomicFile.writeJSON(
            DiarizationResult(engine: "speakerkit", modelIdentifier: "speakerkit/pyannote-community-1",
                              intervals: [], centroids: centroids),
            to: files.diarization)
        let transcript = Transcript(recordingID: root.lastPathComponent, sourceHash: "h", duration: 10,
                                    language: "he", pipelineVersion: Transcript.currentPipelineVersion,
                                    models: .init(asr: "test"), mergeParams: MergeParams().record,
                                    speakers: speakers, turns: [])
        try AtomicFile.writeJSON(transcript, to: files.transcriptJSON)
    }

    /// The rule the whole thing rests on. A name the matcher proposed is the
    /// claim being calibrated; taking it as ground truth asks the matcher to
    /// mark its own work.
    @Test func onlyConfirmedNamesCountAsGroundTruth() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeJob(at: root,
                     speakers: [
                        "SPEAKER_00": .init(displayName: "Pavel", confirmedByUser: true),
                        // The matcher's own guess, and a generic label.
                        "SPEAKER_01": .init(displayName: "Emilia", matchScore: 0.71, confirmedByUser: false),
                        "SPEAKER_02": .init(displayName: "Speaker 3"),
                     ],
                     centroids: ["SPEAKER_00": vector(0), "SPEAKER_01": vector(1), "SPEAKER_02": vector(2)])

        let voices = SpeakerCalibration.labelledVoices(inJobAt: root)
        #expect(voices.map(\.person) == ["Pavel"])
    }

    /// A cluster with no centroid cannot be compared with anything, so it is
    /// not a labelled voice however confidently it is named.
    @Test func aConfirmedNameWithNoCentroidIsNotAVoice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeJob(at: root,
                     speakers: ["SPEAKER_00": .init(displayName: "Pavel", confirmedByUser: true)],
                     centroids: [:])
        #expect(SpeakerCalibration.labelledVoices(inJobAt: root).isEmpty)
    }

    /// The real shape of the owner's library: two people, one recording. The
    /// floor guards a voice recorded again on another day, and nothing here
    /// speaks to that.
    @Test func onePairFromOneRecordingIsNotACalibration() {
        let report = SpeakerCalibration.report(voices: [
            voice("Pavel", job: "job-1", cluster: "SPEAKER_00", seed: 0),
            voice("Emilia", job: "job-1", cluster: "SPEAKER_01", seed: 3),
        ])
        #expect(report.sameSpeakerAcrossRecordings == nil, "the number the floor rests on is missing")
        #expect(report.differentSpeakers?.count == 1)
        #expect(report.separation == nil)
    }

    /// Enrollment copies the cluster centroid, so a person against their own
    /// take is 1.0 by construction. Counted apart so it cannot be mistaken for
    /// evidence that the floor holds.
    @Test func selfSimilarityIsSegregatedFromRealEvidence() {
        let report = SpeakerCalibration.report(voices: [
            voice("Pavel", job: "job-1", cluster: "SPEAKER_00", seed: 0),
            voice("Pavel", job: "job-1", cluster: "SPEAKER_01", seed: 0),
        ])
        #expect(report.sameSpeakerWithinOneRecording?.count == 1)
        #expect(report.sameSpeakerAcrossRecordings == nil)
        #expect((report.sameSpeakerWithinOneRecording?.highest ?? 0) > 0.999)
    }

    @Test func thesamePersonInTwoTakesIsTheEvidenceThatCounts() {
        let report = SpeakerCalibration.report(voices: [
            voice("Pavel", job: "job-1", seed: 0),
            voice("Pavel", job: "job-2", seed: 0.05),
            voice("Emilia", job: "job-2", cluster: "SPEAKER_01", seed: 3),
        ])
        let same = try? #require(report.sameSpeakerAcrossRecordings)
        #expect(same?.count == 1)
        #expect(report.differentSpeakers?.count == 2)
        #expect(report.separation != nil)
    }

    /// Cross-model embeddings are not comparable (§13.2), so they are never
    /// paired rather than being paired and scoring badly.
    @Test func embeddingsFromDifferentEmbeddersAreNeverPaired() {
        let report = SpeakerCalibration.report(voices: [
            voice("Pavel", job: "job-1", seed: 0),
            voice("Pavel", job: "job-2", seed: 0, model: "something/else"),
        ])
        #expect(report.pairs.isEmpty)
        #expect(report.sameSpeakerAcrossRecordings == nil)
    }

    /// The verdict the thresholds are there to deliver: same-person pairs above
    /// the floor, different-person pairs below it.
    @Test func theReportSaysWhatTheThresholdsWouldDo() {
        let identical = SpeakerCalibration.LabelledVoice(
            jobID: "job-2", person: "Pavel", cluster: "SPEAKER_00",
            modelIdentifier: "speakerkit/pyannote-community-1", embedding: vector(0))
        let report = SpeakerCalibration.report(voices: [
            voice("Pavel", job: "job-1", seed: 0),
            identical,
            voice("Emilia", job: "job-3", cluster: "SPEAKER_01", seed: 3),
        ])
        #expect(report.sameSpeakerAboveFloor == 1, "an identical voice must clear the floor")
        #expect(report.differentSpeakersAboveFloor == 0)
        #expect((report.separation ?? -1) > 0, "a positive gap means the floor has somewhere safe to sit")
    }

    @Test func noVoicesMeansNoReportRatherThanAZero() {
        let report = SpeakerCalibration.report(voices: [])
        #expect(report.pairs.isEmpty)
        #expect(report.differentSpeakers == nil)
        #expect(report.separation == nil)
    }
}
