import Foundation
import Testing
@testable import LonghandKit

private func turn(_ id: Int, _ cluster: String, _ start: TimeInterval, _ end: TimeInterval,
                  _ text: String, speaker: String? = nil) -> Transcript.Turn {
    Transcript.Turn(id: id, cluster: cluster, speaker: speaker ?? cluster,
                    start: start, end: end, overlapped: false, text: text)
}

private func fixture(_ turns: [Transcript.Turn],
                     speakers: [String: Transcript.Speaker] = ["SPEAKER_00": .init(displayName: "Speaker 1"),
                                                               "SPEAKER_01": .init(displayName: "Speaker 2")]) -> Transcript {
    Transcript(recordingID: "R", sourceHash: "H", duration: 60, language: "en",
               pipelineVersion: Transcript.currentPipelineVersion,
               models: .init(asr: "whisperkit/large-v3", diarization: "speakerkit/community-1", speakerID: nil),
               mergeParams: .init(boundaryToleranceMs: 250, turnGapSeconds: 1.0),
               speakers: speakers, turns: turns)
}

/// The overlay is what makes a re-merge non-destructive: the transcript is
/// rebuilt from checkpoints and the user's work is reapplied on top (§10
/// COMPLETE→MERGED). These tests are that guarantee.
@Suite struct UserOverlayTests {

    // MARK: - Speaker names

    @Test func nameAppliesToTheClusterAndEveryTurnItOwns() {
        var overlay = UserOverlay()
        overlay.setSpeakerName("Emilia", forCluster: "SPEAKER_00")
        let result = overlay.apply(to: fixture([
            turn(0, "SPEAKER_00", 0, 5, "first"),
            turn(1, "SPEAKER_01", 5, 9, "second"),
            turn(2, "SPEAKER_00", 9, 12, "third"),
        ]))
        #expect(result.speakers["SPEAKER_00"]?.displayName == "Emilia")
        #expect(result.speakers["SPEAKER_00"]?.confirmedByUser == true)
        // Exports read turn.speaker, so it must agree with the table.
        #expect(result.turns.map(\.speaker) == ["Emilia", "Speaker 2", "Emilia"])
    }

    @Test func userNameBeatsAnAutomaticMatchButKeepsItsScore() {
        var overlay = UserOverlay()
        overlay.setSpeakerName("Dana", forCluster: "SPEAKER_00")
        let matched = fixture([turn(0, "SPEAKER_00", 0, 5, "hello")],
                              speakers: ["SPEAKER_00": .init(displayName: "Emilia", matchScore: 0.71,
                                                             confirmedByUser: false)])
        let result = overlay.apply(to: matched)
        #expect(result.speakers["SPEAKER_00"]?.displayName == "Dana")
        #expect(result.speakers["SPEAKER_00"]?.confirmedByUser == true)
        // §6.3-adjacent honesty: the score is a record of what the model said,
        // not a claim about the new name, so keep it rather than fake it away.
        #expect(result.speakers["SPEAKER_00"]?.matchScore == 0.71)
    }

    // MARK: - Text edits

    @Test func editReplacesTheTextAndMarksTheTurn() {
        let original = turn(0, "SPEAKER_00", 12.41, 17.52, "We need to get this done before Wednesday.")
        var overlay = UserOverlay()
        overlay.setText("We need to get this done before Thursday.", forTurn: original)

        let result = overlay.applyReportingStale(to: fixture([original]))
        #expect(result.transcript.turns[0].text == "We need to get this done before Thursday.")
        #expect(result.transcript.turns[0].edited == true)
        #expect(result.staleEdits.isEmpty)
    }

    @Test func applyingTwiceChangesNothingAndIsNotStale() {
        let original = turn(0, "SPEAKER_00", 1.0, 4.0, "original words")
        var overlay = UserOverlay()
        overlay.setText("corrected words", forTurn: original)

        let once = overlay.applyReportingStale(to: fixture([original]))
        let twice = overlay.applyReportingStale(to: once.transcript)
        #expect(twice.transcript.turns[0].text == "corrected words")
        #expect(twice.transcript.turns[0].edited == true)
        #expect(twice.staleEdits.isEmpty, "an already-applied edit is applied, not stale")
    }

    /// A re-merge with a larger turn gap absorbs the following turn: `start`
    /// survives, `end` does not. That is why the anchor uses `start` only.
    @Test func editSurvivesATurnJoinThatChangesTheEnd() {
        let before = turn(0, "SPEAKER_00", 3.0, 6.0, "the quick brown fox")
        var overlay = UserOverlay()
        overlay.setText("the quick brown FOX", forTurn: before)

        let afterJoin = fixture([turn(0, "SPEAKER_00", 3.0, 11.5, "the quick brown fox")])
        let result = overlay.applyReportingStale(to: afterJoin)
        #expect(result.transcript.turns[0].text == "the quick brown FOX")
        #expect(result.staleEdits.isEmpty)
    }

    @Test func editSurvivesASmallBoundaryShiftWithinTolerance() {
        let before = turn(0, "SPEAKER_00", 3.00, 6.0, "hello there")
        var overlay = UserOverlay()
        overlay.setText("hello, there", forTurn: before)

        let shifted = fixture([turn(0, "SPEAKER_00", 3.18, 6.1, "hello there")])
        #expect(overlay.apply(to: shifted).turns[0].text == "hello, there")
    }

    @Test func changedWordsMakeTheEditStaleRatherThanOverwriting() {
        let before = turn(0, "SPEAKER_00", 2.0, 5.0, "meet me at eight")
        var overlay = UserOverlay()
        overlay.setText("meet me at 8", forTurn: before)

        // A re-transcription produced different words at the same place.
        let retranscribed = fixture([turn(0, "SPEAKER_00", 2.0, 5.0, "meet me at night")])
        let result = overlay.applyReportingStale(to: retranscribed)

        #expect(result.transcript.turns[0].text == "meet me at night", "machine text is left alone")
        #expect(result.transcript.turns[0].edited == nil)
        #expect(result.staleCount == 1)
        #expect(result.staleEdits.first?.reason == .textChanged)
        // The authored text is still recoverable, never silently dropped.
        #expect(result.staleEdits.first?.edit.newText == "meet me at 8")
    }

    @Test func aVanishedTurnLeavesTheEditStaleNotLost() {
        let before = turn(0, "SPEAKER_00", 40.0, 44.0, "somewhere in the middle")
        var overlay = UserOverlay()
        overlay.setText("corrected", forTurn: before)

        let result = overlay.applyReportingStale(to: fixture([turn(0, "SPEAKER_00", 0, 5, "different turn")]))
        #expect(result.staleEdits.first?.reason == .noMatchingTurn)
        #expect(overlay.turnEdits.count == 1, "the edit stays in the overlay")
    }

    @Test func editingBackToTheMachinesWordsRecordsNothing() {
        let original = turn(0, "SPEAKER_00", 1.0, 4.0, "as transcribed")
        var overlay = UserOverlay()
        overlay.setText("as transcribed", forTurn: original)
        #expect(overlay.turnEdits.isEmpty)
    }

    @Test func clearingAnEditRestoresTheDerivedText() {
        let original = turn(0, "SPEAKER_00", 1.0, 4.0, "as transcribed")
        var overlay = UserOverlay()
        overlay.setText("edited", forTurn: original)
        overlay.clearText(forTurn: original)
        #expect(overlay.turnEdits.isEmpty)
        #expect(overlay.apply(to: fixture([original])).turns[0].text == "as transcribed")
    }

    @Test func reEditingTheSamePassageReplacesTheEarlierEdit() {
        let original = turn(0, "SPEAKER_00", 1.0, 4.0, "one")
        var overlay = UserOverlay()
        overlay.setText("two", forTurn: original)
        overlay.setText("three", forTurn: original)
        #expect(overlay.turnEdits.count == 1)
        #expect(overlay.apply(to: fixture([original])).turns[0].text == "three")
    }

    @Test func hebrewEditAnchorsThroughExportStyleBidiControls() {
        let original = turn(0, "SPEAKER_00", 0.5, 4.0, "שלום, זו בדיקת תמלול")
        var overlay = UserOverlay()
        overlay.setText("שלום, זו בדיקת תמלול!", forTurn: original)

        // Same words, re-derived with directional isolates around them.
        let isolated = turn(0, "SPEAKER_00", 0.5, 4.0, BidiText.isolatedForExport("שלום, זו בדיקת תמלול"))
        let result = overlay.applyReportingStale(to: fixture([isolated]))
        #expect(result.staleEdits.isEmpty, "bidi controls are shape, not content")
        #expect(result.transcript.turns[0].text == "שלום, זו בדיקת תמלול!")
    }

    // MARK: - Speaker reassignment

    @Test func reassignmentChangesTheShownSpeakerButNotTheDiarizersClaim() {
        let misattributed = turn(1, "SPEAKER_00", 5.0, 9.0, "actually the other person")
        var overlay = UserOverlay()
        overlay.assign(turn: misattributed, toCluster: "SPEAKER_01")

        let result = overlay.apply(to: fixture([turn(0, "SPEAKER_00", 0, 5, "mine"), misattributed]))
        #expect(result.turns[1].speaker == "Speaker 2")
        #expect(result.turns[1].assignedCluster == "SPEAKER_01")
        // Enrollment eligibility and centroid lookup read `cluster`, so the
        // machine's own attribution must survive untouched (§9.2).
        #expect(result.turns[1].cluster == "SPEAKER_00")
        #expect(result.turns[0].speaker == "Speaker 1")
    }

    @Test func reassignmentFollowsTheTurnThroughASplit() {
        let original = turn(0, "SPEAKER_00", 10.0, 20.0, "one long stretch")
        var overlay = UserOverlay()
        overlay.assign(turn: original, toCluster: "SPEAKER_01")

        // A re-merge split it in two; both halves' midpoints fall inside.
        let split = fixture([turn(0, "SPEAKER_00", 10.0, 15.0, "one long"),
                             turn(1, "SPEAKER_00", 15.0, 20.0, "stretch")])
        let result = overlay.apply(to: split)
        #expect(result.turns.allSatisfy { $0.assignedCluster == "SPEAKER_01" })
    }

    @Test func reassigningBackToTheOriginalClusterRemovesTheOverride() {
        let original = turn(0, "SPEAKER_00", 1.0, 4.0, "text")
        var overlay = UserOverlay()
        overlay.assign(turn: original, toCluster: "SPEAKER_01")
        overlay.assign(turn: original, toCluster: "SPEAKER_00")
        #expect(overlay.speakerRanges.isEmpty)
    }

    @Test func reassignmentToAFreshClusterCarriesItsName() {
        let original = turn(0, "SPEAKER_00", 1.0, 4.0, "text")
        var overlay = UserOverlay()
        overlay.assign(turn: original, toCluster: "SPEAKER_09", displayName: "Guest")
        let result = overlay.apply(to: fixture([original]))
        #expect(result.turns[0].speaker == "Guest")
        #expect(result.speakers["SPEAKER_09"]?.displayName == "Guest")
    }

    // MARK: - User-defined speakers

    /// The diarizer folded a third person into someone else's cluster, so
    /// there is no cluster to move the passage *to*. Inventing one is the only
    /// correction available, and it has to survive a rebuild like any other.
    @Test func aPassageCanBeMovedToASpeakerTheDiarizerNeverFound() {
        let misheard = turn(1, "SPEAKER_00", 5.0, 9.0, "a third voice")
        let cluster = UserOverlay.mintSpeakerCluster()
        var overlay = UserOverlay()
        overlay.assign(turn: misheard, toCluster: cluster, displayName: "Guest")

        let result = overlay.apply(to: fixture([turn(0, "SPEAKER_00", 0, 5, "mine"), misheard]))
        #expect(UserOverlay.isUserDefined(cluster: cluster))
        #expect(result.turns[1].speaker == "Guest")
        #expect(result.turns[1].assignedCluster == cluster)
        #expect(result.speakers[cluster]?.displayName == "Guest")
        // Invented, so the user said it: there is no model claim to weigh it
        // against (§13.1).
        #expect(result.speakers[cluster]?.confirmedByUser == true)
        #expect(result.speakers[cluster]?.matchScore == nil)
        // And the diarizer's own answer is still there for enrollment to read.
        #expect(result.turns[1].cluster == "SPEAKER_00")
    }

    @Test func mintedClustersDoNotCollide() {
        let keys = Set((0..<50).map { _ in UserOverlay.mintSpeakerCluster() })
        #expect(keys.count == 50)
    }

    /// The second passage is assigned by picking the name off a list, so it
    /// arrives with no `displayName`. It still has to name the speaker, or
    /// undoing the *first* one would leave the cluster anonymous.
    @Test func aSecondPassageForAnInventedSpeakerInheritsTheirName() {
        let first = turn(1, "SPEAKER_00", 5.0, 9.0, "one")
        let second = turn(3, "SPEAKER_00", 20.0, 24.0, "two")
        let cluster = UserOverlay.mintSpeakerCluster()
        var overlay = UserOverlay()
        overlay.assign(turn: first, toCluster: cluster, displayName: "Guest")
        overlay.assign(turn: second, toCluster: cluster)
        overlay.assign(turn: first, toCluster: first.cluster)   // undo the first

        let result = overlay.apply(to: fixture([first, second]))
        #expect(result.turns[0].speaker == "Speaker 1")
        #expect(result.turns[1].speaker == "Guest")
    }

    @Test func renamingAnInventedSpeakerBeatsTheNameTheRangeCarries() {
        let misheard = turn(0, "SPEAKER_00", 1.0, 4.0, "text")
        let cluster = UserOverlay.mintSpeakerCluster()
        var overlay = UserOverlay()
        overlay.assign(turn: misheard, toCluster: cluster, displayName: "Guest")
        overlay.setSpeakerName("Dana", forCluster: cluster)

        #expect(overlay.apply(to: fixture([misheard])).turns[0].speaker == "Dana")
    }

    /// Undoing the last passage removes the speaker from the transcript
    /// entirely, so their name must not linger in the overlay. It would come
    /// back to haunt the next passage that happened to mint the same key, and
    /// it makes `isEmpty` lie about whether anything is authored.
    @Test func undoingTheLastPassageForgetsTheInventedSpeaker() {
        let misheard = turn(0, "SPEAKER_00", 1.0, 4.0, "text")
        let cluster = UserOverlay.mintSpeakerCluster()
        var overlay = UserOverlay()
        overlay.assign(turn: misheard, toCluster: cluster, displayName: "Guest")
        overlay.setSpeakerName("Dana", forCluster: cluster)
        overlay.assign(turn: misheard, toCluster: misheard.cluster)

        #expect(overlay.speakerRanges.isEmpty)
        #expect(overlay.speakerNames.isEmpty)
        #expect(overlay.isEmpty)
    }

    /// A name the user gave a *diarized* cluster is a statement about a voice
    /// the model can still match, so it outlives any reassignment.
    @Test func undoingAReassignmentKeepsNamesGivenToRealClusters() {
        let misheard = turn(0, "SPEAKER_00", 1.0, 4.0, "text")
        var overlay = UserOverlay()
        overlay.setSpeakerName("Emilia", forCluster: "SPEAKER_00")
        overlay.assign(turn: misheard, toCluster: "SPEAKER_01")
        overlay.assign(turn: misheard, toCluster: "SPEAKER_00")

        #expect(overlay.speakerNames["SPEAKER_00"]?.displayName == "Emilia")
    }

    // MARK: - Markers

    @Test func markersLandOnTheTranscriptInTimeOrder() {
        var overlay = UserOverlay()
        overlay.addMarker(at: 42.0, label: "decision")
        overlay.addMarker(at: 12.5)
        let result = overlay.apply(to: fixture([turn(0, "SPEAKER_00", 0, 60, "…")]))
        #expect(result.markers?.map(\.time) == [12.5, 42.0])
        #expect(result.markers?.last?.label == "decision")
    }

    @Test func anEmptyOverlayLeavesTheTranscriptAlone() {
        let base = fixture([turn(0, "SPEAKER_00", 0, 5, "unchanged", speaker: "Speaker 1")])
        let overlay = UserOverlay()
        #expect(overlay.isEmpty)
        #expect(overlay.apply(to: base) == base)
    }

    /// `turn.speaker` is a denormalized copy of the speakers table that
    /// exporters read directly, so applying always re-resolves it. A transcript
    /// whose copy has drifted is repaired, not preserved.
    @Test func applyingRepairsATurnWhoseCachedNameDriftedFromTheTable() {
        let drifted = fixture([turn(0, "SPEAKER_00", 0, 5, "text", speaker: "stale name")])
        #expect(UserOverlay().apply(to: drifted).turns[0].speaker == "Speaker 1")
    }

    @Test func overlayRoundTripsThroughJSON() throws {
        var overlay = UserOverlay()
        overlay.setSpeakerName("Emilia", forCluster: "SPEAKER_00")
        overlay.setText("corrected", forTurn: turn(0, "SPEAKER_00", 1.0, 4.0, "original"))
        overlay.assign(turn: turn(1, "SPEAKER_01", 5.0, 9.0, "x"), toCluster: "SPEAKER_00")
        overlay.addMarker(at: 3.5, label: "here")

        let data = try JSONEncoder().encode(overlay)
        #expect(try JSONDecoder().decode(UserOverlay.self, from: data) == overlay)
    }
}

/// The export choke point: everything the user authored has to reach every
/// format, and a new export path must not be able to skip it.
@Suite struct OverlayExportTests {

    private func temporaryJobFiles() -> JobFiles {
        JobFiles(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("longhand-overlay-tests-\(UUID())"))
    }

    @Test func everyFormatCarriesTheEditedText() throws {
        let files = temporaryJobFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }

        let original = turn(0, "SPEAKER_00", 1.0, 4.0, "meet me at eight", speaker: "Speaker 1")
        var overlay = UserOverlay()
        overlay.setSpeakerName("Emilia", forCluster: "SPEAKER_00")
        overlay.setText("meet me at 8", forTurn: original)
        try AtomicFile.writeJSON(overlay, to: files.overlay)

        let result = try TranscriptExporter.writeAll(fixture([original]), to: files)
        #expect(result.staleEdits.isEmpty)

        for url in [files.transcriptJSON, files.transcriptText, files.transcriptMarkdown] {
            let written = try String(contentsOf: url, encoding: .utf8)
            #expect(written.contains("meet me at 8"), "\(url.lastPathComponent) missing the edit")
            #expect(!written.contains("at eight"), "\(url.lastPathComponent) kept the machine text")
            #expect(written.contains("Emilia"), "\(url.lastPathComponent) missing the rename")
        }
    }

    /// A speaker who exists only because the user said so still has to reach
    /// every format: the correction is worthless if the shared transcript
    /// keeps the wrong name.
    @Test func anInventedSpeakerReachesEveryFormat() throws {
        let files = temporaryJobFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }

        let misheard = turn(1, "SPEAKER_00", 5.0, 9.0, "a third voice", speaker: "Speaker 1")
        var overlay = UserOverlay()
        overlay.assign(turn: misheard, toCluster: UserOverlay.mintSpeakerCluster(), displayName: "Guest")
        try AtomicFile.writeJSON(overlay, to: files.overlay)

        try TranscriptExporter.writeAll(
            fixture([turn(0, "SPEAKER_00", 0, 5, "mine", speaker: "Speaker 1"), misheard]), to: files)

        for url in [files.transcriptText, files.transcriptMarkdown] {
            let written = try String(contentsOf: url, encoding: .utf8)
            #expect(written.contains("Guest"), "\(url.lastPathComponent) missing the invented speaker")
            // The other passage keeps the diarizer's answer: this was a
            // one-passage correction, not a rename.
            #expect(written.contains("Speaker 1"), "\(url.lastPathComponent) lost the untouched speaker")
        }
    }

    @Test func exportingWithoutAnOverlayIsUnchanged() throws {
        let files = temporaryJobFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let result = try TranscriptExporter.writeAll(
            fixture([turn(0, "SPEAKER_00", 0, 5, "plain", speaker: "Speaker 1")]), to: files)
        #expect(result.staleEdits.isEmpty)
        #expect(try String(contentsOf: files.transcriptText, encoding: .utf8).contains("plain"))
    }

    /// Truncated checkpoints are never trusted; for the overlay the stake is
    /// the user's own writing, so the export fails loudly instead of shipping
    /// a transcript that quietly lost it.
    @Test func aCorruptOverlayFailsTheExportRatherThanBeingIgnored() throws {
        let files = temporaryJobFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try files.createDirectory()
        try Data("{ not json".utf8).write(to: files.overlay)

        #expect(throws: LonghandError.self) {
            try TranscriptExporter.writeAll(fixture([turn(0, "SPEAKER_00", 0, 5, "x")]), to: files)
        }
    }

    @Test func markersReachMarkdownAndJSONButNotSubtitles() throws {
        let files = temporaryJobFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }

        var overlay = UserOverlay()
        overlay.addMarker(at: 2.0, label: "decision")
        try AtomicFile.writeJSON(overlay, to: files.overlay)
        try TranscriptExporter.writeAll(
            fixture([turn(0, "SPEAKER_00", 3.0, 8.0, "after the marker", speaker: "Speaker 1")]), to: files)

        #expect(try String(contentsOf: files.transcriptMarkdown, encoding: .utf8).contains("decision"))
        #expect(try String(contentsOf: files.transcriptJSON, encoding: .utf8).contains("decision"))
        // Plain text carries speech only; a marker is not something anyone said.
        #expect(!(try String(contentsOf: files.transcriptText, encoding: .utf8).contains("decision")))
    }

    @Test func staleEditsAreReportedToTheCaller() throws {
        let files = temporaryJobFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }

        var overlay = UserOverlay()
        overlay.setText("corrected", forTurn: turn(0, "SPEAKER_00", 1.0, 4.0, "original words"))
        try AtomicFile.writeJSON(overlay, to: files.overlay)

        let result = try TranscriptExporter.writeAll(
            fixture([turn(0, "SPEAKER_00", 1.0, 4.0, "completely different words")]), to: files)
        #expect(result.staleCount == 1)
        #expect(try String(contentsOf: files.transcriptText, encoding: .utf8).contains("completely different"))
    }
}

/// Re-editing is the case the first implementation got wrong: callers hand in
/// a turn whose text already has the overlay applied, so the anchor has to be
/// carried forward rather than recomputed.
@Suite struct ReEditingTests {

    private func renderedTurn(_ overlay: UserOverlay, base: Transcript.Turn) -> Transcript.Turn {
        overlay.apply(to: fixture([base])).turns[0]
    }

    @Test func correctingYourOwnCorrectionKeepsIt() {
        let machine = turn(0, "SPEAKER_00", 1.0, 4.0, "machine words", speaker: "Speaker 1")
        var overlay = UserOverlay()

        overlay.setText("first correction", forTurn: machine)
        let afterFirst = renderedTurn(overlay, base: machine)
        #expect(afterFirst.text == "first correction")

        // The second edit is made against what the user can see (the already
        // corrected turn), which is exactly how both shells call this.
        overlay.setText("second correction", forTurn: afterFirst)

        let result = overlay.applyReportingStale(to: fixture([machine]))
        #expect(result.transcript.turns[0].text == "second correction")
        #expect(result.transcript.turns[0].edited == true)
        #expect(result.staleEdits.isEmpty, "re-editing must not strand the edit")
        #expect(overlay.turnEdits.count == 1)
    }

    @Test func editingBackToTheMachinesWordsAfterACorrectionIsAnUnEdit() {
        let machine = turn(0, "SPEAKER_00", 1.0, 4.0, "machine words", speaker: "Speaker 1")
        var overlay = UserOverlay()
        overlay.setText("a correction", forTurn: machine)
        let corrected = renderedTurn(overlay, base: machine)

        overlay.setText("machine words", forTurn: corrected)
        #expect(overlay.turnEdits.isEmpty, "typing the original back removes the correction")
        #expect(overlay.apply(to: fixture([machine])).turns[0].text == "machine words")
    }

    @Test func threeEditsDeepStillResolvesToTheLatest() {
        let machine = turn(0, "SPEAKER_00", 2.0, 5.0, "one", speaker: "Speaker 1")
        var overlay = UserOverlay()
        for text in ["two", "three", "four"] {
            let shown = renderedTurn(overlay, base: machine)
            overlay.setText(text, forTurn: shown)
        }
        let result = overlay.applyReportingStale(to: fixture([machine]))
        #expect(result.transcript.turns[0].text == "four")
        #expect(result.staleEdits.isEmpty)
    }
}


/// Unattributed turns keep their human label. An overlay exists as soon as a
/// marker is flagged, so this fires on ordinary recordings.
@Suite struct UnknownSpeakerTests {

    @Test func anOverlayDoesNotRenameUnknownSpeakerToItsClusterKey() {
        let unattributed = Transcript.Turn(id: 0, cluster: "UNKNOWN", speaker: "Unknown speaker",
                                           start: 0, end: 5, overlapped: false, text: "hello there")
        let base = fixture([unattributed], speakers: [:])

        var overlay = UserOverlay()
        overlay.addMarker(at: 1.0)
        let result = overlay.apply(to: base)

        #expect(result.turns[0].speaker == "Unknown speaker")
        #expect(!TranscriptExporter.text(result).contains("UNKNOWN:"))
    }
}

/// A correction with a line break in it must not corrupt the formats that
/// carry one turn per record.
@Suite struct ExportRobustnessTests {

    private func multiLineFixture() -> Transcript {
        fixture([turn(0, "SPEAKER_00", 0, 4, "first line\nsecond line", speaker: "Speaker 1")])
    }

    @Test func plainTextKeepsOneTurnPerLine() {
        let text = TranscriptExporter.text(multiLineFixture())
        #expect(text.contains("first line\nsecond line"),
                "the turn's own line break is preserved verbatim")
        #expect(text.hasPrefix("[00:00] Speaker 1: "))
    }
}
