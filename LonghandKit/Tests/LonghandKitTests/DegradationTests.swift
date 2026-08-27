import Foundation
import Testing
@testable import LonghandKit

/// Typing the degradations changed the shape of `job.json`, and every job
/// already on a device was written in the old shape. A record that will not
/// decode is a recording the library cannot show, so the migration matters more
/// than the feature that motivated it.
@Suite struct DegradationTests {

    private func decodeRecord(_ json: String) throws -> JobRecord {
        try JSONDecoder().decode(JobRecord.self, from: Data(json.utf8))
    }

    /// The shape every job on the owner's phone is written in today.
    @Test func aLegacyRecordStillDecodes() throws {
        let record = try decodeRecord("""
        {
          "id": "98D829D6-45D4-4F03-A09D-FB6EC7206367",
          "title": "22 Aug 2026 at 19:04",
          "createdAt": 809107485.924324,
          "state": "COMPLETE",
          "lastCheckpointState": "COMPLETE",
          "degradations": [
            "Diarization unavailable: the transcript has timestamps but no speaker labels. Reason: offline.",
            "Recording was very quiet; volume boosted by 12 dB for transcription (original audio unchanged)."
          ]
        }
        """)
        #expect(record.degradations.count == 2)
        #expect(record.degradations[0].kind == .diarizationUnavailable)
        #expect(record.degradations[1].kind == .quietBoostApplied)
        // The prose is preserved exactly: it is what the user reads.
        #expect(record.degradations[0].message.hasSuffix("Reason: offline."))
    }

    /// Every message the pipeline has ever written maps to its own kind, so an
    /// existing job keeps the behaviour its note used to drive.
    @Test func everyLegacyMessageIsRecognized() {
        let cases: [(String, Degradation.Kind)] = [
            ("Diarization unavailable: the transcript has timestamps but no speaker labels. Reason: x",
             .diarizationUnavailable),
            ("Recording was very quiet; volume boosted by 9 dB for transcription (original audio unchanged).",
             .quietBoostApplied),
            ("No engine declares support for “he”; used whisperkit instead.", .engineSubstituted),
            ("No engine supports mixed-language auto-detection; used apple with a single language instead.",
             .engineSubstituted),
            ("No speech detected in this recording.", .noSpeechDetected),
            ("No speech kept: 3 passages were filtered as likely hallucination.",
             .speechFilteredAsHallucination),
            ("2 edits could not be reattached after this transcript changed.", .editsNotReattached),
        ]
        for (message, expected) in cases {
            #expect(Degradation.inferKind(fromLegacy: message) == expected, "\(message)")
        }
    }

    /// Prose the inference does not know keeps its message rather than being
    /// dropped: §17 says the note is never silent, and an uncategorized note
    /// still reads.
    @Test func anUnrecognizedLegacyMessageSurvivesUncategorized() {
        let degradation = Degradation(from: "Something nobody has written yet.")
        #expect(degradation.kind == .unspecified)
        #expect(degradation.message == "Something nobody has written yet.")
    }

    /// A kind written by a later version must not fail the whole record.
    @Test func anUnknownKindKeepsItsMessage() throws {
        let record = try decodeRecord("""
        {
          "id": "98D829D6-45D4-4F03-A09D-FB6EC7206367",
          "title": "t", "createdAt": 0, "state": "COMPLETE",
          "lastCheckpointState": "COMPLETE",
          "degradations": [{ "kind": "somethingFromTheFuture", "message": "Kept anyway." }]
        }
        """)
        #expect(record.degradations.first?.kind == .unspecified)
        #expect(record.degradations.first?.message == "Kept anyway.")
    }

    @Test func aRecordWithNoDegradationsDecodes() throws {
        let record = try decodeRecord("""
        { "id": "98D829D6-45D4-4F03-A09D-FB6EC7206367", "title": "t", "createdAt": 0,
          "state": "IMPORTED", "lastCheckpointState": "IMPORTED", "degradations": [] }
        """)
        #expect(record.degradations.isEmpty)
    }

    @Test func typedDegradationsRoundTrip() throws {
        var record = JobRecord(id: UUID(), title: "t", createdAt: Date(),
                               state: .complete, lastCheckpointState: .complete)
        record.degradations = [Degradation(kind: .diarizationUnavailable, message: "no labels"),
                               Degradation(kind: .editsNotReattached, message: "1 edit")]
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(JobRecord.self, from: data)
        #expect(decoded.degradations == record.degradations)
    }

    /// Stages re-run on resume, and the same note reached twice is one note.
    @Test func appendingIsIdempotent() {
        var notes: [Degradation] = []
        let note = Degradation(kind: .diarizationUnavailable, message: "no labels")
        notes.appendIfNew(note)
        notes.appendIfNew(note)
        #expect(notes.count == 1)
        #expect(notes.contains(kind: .diarizationUnavailable))
        #expect(!notes.contains(kind: .quietBoostApplied))
    }

    /// Two diarization failures with different causes are two different notes:
    /// the reason is the part worth keeping (§17), so equality is not by kind.
    @Test func notesOfTheSameKindWithDifferentCausesBothSurvive() {
        var notes: [Degradation] = []
        notes.appendIfNew(Degradation(kind: .diarizationUnavailable, message: "Reason: offline."))
        notes.appendIfNew(Degradation(kind: .diarizationUnavailable, message: "Reason: no space."))
        #expect(notes.count == 2)
    }
}

private extension Degradation {
    /// Decodes a bare legacy string the way an old `job.json` carries it.
    init(from legacy: String) {
        let data = try! JSONEncoder().encode(legacy)
        self = try! JSONDecoder().decode(Degradation.self, from: data)
    }
}
