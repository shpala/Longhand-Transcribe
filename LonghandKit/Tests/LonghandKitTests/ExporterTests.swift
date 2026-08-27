import Foundation
import Testing
@testable import LonghandKit

private func fixtureTranscript() -> Transcript {
    Transcript(
        recordingID: "TEST-1",
        sourceHash: "deadbeef",
        duration: 20.0,
        language: "he",
        pipelineVersion: Transcript.currentPipelineVersion,
        models: .init(asr: "test/fixture", diarization: "test/fixture"),
        mergeParams: .init(boundaryToleranceMs: 250, turnGapSeconds: 1.0),
        speakers: [
            "SPEAKER_00": .init(displayName: "Me", matchScore: 0.93, confirmedByUser: true),
            "SPEAKER_01": .init(displayName: "Speaker 2"),
        ],
        turns: [
            .init(id: 0, cluster: "SPEAKER_00", speaker: "Me", start: 1.0, end: 4.0,
                  overlapped: false, text: "I looked at the issue yesterday."),
            // Code-switched Hebrew/English turn (§15.4, §18.2 golden sample).
            .init(id: 1, cluster: "SPEAKER_01", speaker: "Speaker 2", start: 5.0, end: 9.5,
                  overlapped: false, text: "צריך לסיים את זה לפני Wednesday, בסדר?"),
            .init(id: 2, cluster: "SPEAKER_00", speaker: "Me", start: 9.4, end: 12.0,
                  overlapped: true, text: "yes absolutely"),
        ]
    )
}

@Suite struct ExporterTests {

    let rli = "\u{2067}", lri = "\u{2066}", pdi = "\u{2069}"

    @Test func exportsWrapRTLTurnsInDirectionalIsolates() {
        let text = TranscriptExporter.text(fixtureTranscript())
        #expect(text.contains("\(rli)צריך לסיים את זה לפני Wednesday, בסדר?\(pdi)"))
        // Pure-LTR text stays untouched.
        #expect(text.contains("I looked at the issue yesterday."))
        #expect(!text.contains("\(lri)I looked"))
        #expect(TranscriptExporter.markdown(fixtureTranscript()).contains("\(rli)צריך"))
    }

    @Test func overlapFlagIsNeverSilentlyDropped() {
        let t = fixtureTranscript()
        #expect(TranscriptExporter.text(t).contains("[overlap]"))
        #expect(TranscriptExporter.markdown(t).contains("*(overlapping)*"))
    }

    @Test func canonicalJSONRoundTrips() throws {
        let t = fixtureTranscript()
        let data = try TranscriptExporter.canonicalJSON(t)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(decoded == t)
    }

    @Test func canonicalJSONFieldNamesMatchSpec() throws {
        // §13.1 field names are a contract, not an implementation detail.
        let data = try TranscriptExporter.canonicalJSON(fixtureTranscript())
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["recordingID"] != nil)
        #expect(json["sourceHash"] != nil)
        #expect(json["pipelineVersion"] != nil)
        let models = json["models"] as! [String: Any]
        #expect(models["asr"] as? String == "test/fixture")
        let mergeParams = json["mergeParams"] as! [String: Any]
        #expect(mergeParams["boundaryToleranceMs"] as? Int == 250)
        let speakers = json["speakers"] as! [String: [String: Any]]
        #expect(speakers["SPEAKER_00"]?["matchScore"] as? Double == 0.93)
        #expect(speakers["SPEAKER_00"]?["confirmedByUser"] as? Bool == true)
        // §6.3 / §13.1: no field named "confidence" anywhere in the canonical JSON.
        let raw = String(decoding: data, as: UTF8.self)
        #expect(!raw.contains("\"confidence\""))
        let turns = json["turns"] as! [[String: Any]]
        #expect(turns[2]["overlapped"] as? Bool == true)
    }
}

@Suite struct BidiTextTests {

    @Test func baseDirectionDetection() {
        #expect(BidiText.baseDirection(of: "hello world") == .ltr)
        #expect(BidiText.baseDirection(of: "שלום עולם") == .rtl)
        #expect(BidiText.baseDirection(of: "· שלום") == .rtl)
        #expect(BidiText.baseDirection(of: "123 456") == .neutral)
        // First strong character wins even in mixed text.
        #expect(BidiText.baseDirection(of: "ok שלום") == .ltr)
        #expect(BidiText.baseDirection(of: "שלום ok") == .rtl)
    }

    @Test func isolationOnlyWhenRTLPresent() {
        #expect(BidiText.isolatedForExport("plain english") == "plain english")
        let mixed = BidiText.isolatedForExport("שלום Wednesday")
        #expect(mixed.hasPrefix("\u{2067}"))
        #expect(mixed.hasSuffix("\u{2069}"))
        let ltrBase = BidiText.isolatedForExport("meeting עם דנה")
        #expect(ltrBase.hasPrefix("\u{2066}"))
    }
}

/// §14.1 as a test rather than a habit: speaker embeddings and capture
/// location must never reach transcript.json or any export. Both are things a
/// future change could add "for convenience" with every other test still green.
@Suite struct ExportPrivacyTests {

    /// Allow-list rather than a blocklist: a newly added Transcript field has
    /// to be considered here before it can ship in the canonical JSON.
    @Test func canonicalJSONCarriesOnlyTheKeysTheSpecAllows() throws {
        let data = try TranscriptExporter.canonicalJSON(fixtureTranscript())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allowed: Set<String> = [
            "recordingID", "sourceHash", "duration", "language", "pipelineVersion",
            "models", "mergeParams", "speakers", "turns", "markers",
        ]
        let unexpected = Set(object.keys).subtracting(allowed)
        #expect(unexpected.isEmpty,
                "new top-level key(s) in the canonical transcript: \(unexpected.sorted()). Is this private data?")
    }

    @Test func noExportMentionsLocationOrEmbeddings() throws {
        let transcript = fixtureTranscript()
        let forbidden = ["latitude", "longitude", "centroid", "embedding",
                         "horizontalAccuracy", "location"]
        let renderings = [
            "json": String(decoding: try TranscriptExporter.canonicalJSON(transcript), as: UTF8.self),
            "text": TranscriptExporter.text(transcript),
            "markdown": TranscriptExporter.markdown(transcript),
        ]
        for (name, rendering) in renderings {
            for term in forbidden {
                #expect(!rendering.lowercased().contains(term),
                        "\(name) export mentions \(term)")
            }
        }
    }

    /// The models that hold the private data must not be encodable into a
    /// transcript at all. The compiler cannot enforce that, so pin the shape.
    @Test func theTranscriptModelHasNowhereToPutALocation() throws {
        let mirror = Mirror(reflecting: fixtureTranscript())
        let names = Set(mirror.children.compactMap(\.label))
        #expect(!names.contains("location"))
        #expect(!names.contains("centroids"))
        #expect(!names.contains("embeddings"))
    }
}
