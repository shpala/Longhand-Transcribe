import Foundation
import Observation
import LonghandKit

/// What the transcript screen shows and every correction it can make, shared
/// by the iOS and Mac shells. The views keep the platform parts: the player,
/// presentation, and how a failure is reported.
///
/// Corrections reload the data and nothing else. The Mac view used to reload
/// the player along with it, so renaming a speaker stopped playback and
/// rewound to 0:00.
@Observable
@MainActor
public final class TranscriptScreenModel {

    public let jobID: UUID

    public private(set) var transcript: Transcript?
    public private(set) var record: JobRecord?
    /// Local display only, never part of any export.
    public private(set) var location: CapturedLocation?
    /// §5.4 capture stats: what separates "the mic heard nothing" from "the
    /// model heard nothing" on the no-speech screen.
    public private(set) var appliedGainDb: Double?
    public private(set) var inputLevelDbFS: Double?
    /// §6.4 passages the filter removed, read from `10_asr.json`.
    public private(set) var suppressedSpans: [SuppressedSpan] = []
    public private(set) var index = TranscriptIndex(turns: [])
    /// Before the first load, "no transcript" means still loading; after, it
    /// means the file could not be read.
    public private(set) var didLoad = false

    /// Markers each turn draws among its own words, worked out once per load.
    /// Both views used to recompute every turn's placements for every row,
    /// which made a marked transcript quadratic to render.
    private var placements: [Int: [MarkerPlacement.Placed]] = [:]
    private var inlineMarkerIDs: Set<UUID> = []

    public let files: JobFiles

    public convenience init(jobID: UUID) {
        self.init(jobID: jobID, files: JobStore.files(for: jobID))
    }

    /// For tests, which stage a job folder outside the library.
    init(jobID: UUID, files: JobFiles) {
        self.jobID = jobID
        self.files = files
    }

    /// COMPLETE on paper, unreadable on disk. The original audio is untouched,
    /// so a re-transcribe rebuilds it.
    public var transcriptUnreadable: Bool {
        didLoad && record?.state == .complete && transcript == nil
    }

    public func load() {
        record = try? AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job") ?? nil
        transcript = try? AtomicFile.readJSON(Transcript.self, from: files.transcriptJSON, stage: "COMPLETE") ?? nil
        let diagnostics = ImportDiagnostics(
            metadata: (try? AtomicFile.readJSON(ImportMetadata.self, from: files.metadata, stage: "job")) ?? nil)
        location = diagnostics.location
        appliedGainDb = diagnostics.appliedGainDb
        inputLevelDbFS = diagnostics.inputLevelDbFS
        suppressedSpans = SuppressedSpans.load(from: files)
        // Drives the karaoke highlight; nil for degraded or older jobs, which
        // fall back to the turn-level highlight (§17).
        let words = (try? AtomicFile.readJSON(MergeOutput.self, from: files.mergedWords, stage: "MERGED") ?? nil)?.words
        index = TranscriptIndex(turns: transcript?.turns ?? [], words: words ?? [])
        placeMarkers()
        didLoad = true
    }

    // MARK: - Reading

    public func hits(for query: String) -> [TranscriptSearch.Hit] {
        guard let transcript else { return [] }
        return TranscriptSearch.matches(query: query, in: transcript)
    }

    /// An unconfirmed automatic match (§9.3): a user statement always beats it.
    public func isAutoLabeled(_ turn: Transcript.Turn) -> Bool {
        let speaker = transcript?.speakers[turn.effectiveCluster]
        return speaker?.matchScore != nil && speaker?.confirmedByUser != true
    }

    /// Everyone this turn could be reassigned to, in a stable order.
    public func otherSpeakers(than turn: Transcript.Turn) -> [(cluster: String, name: String)] {
        guard let transcript else { return [] }
        return transcript.speakers.keys.sorted()
            .filter { $0 != turn.effectiveCluster }
            .map { ($0, transcript.displayName(forCluster: $0)) }
    }

    /// Word timings for the rows that need them: the playing one and any
    /// carrying a marker (§15.2 ⟨R-16⟩). Nil for the rest.
    public func renderedWords(at position: Int, isCurrent: Bool) -> [MergedWord]? {
        guard isCurrent || !placedMarkers(at: position).isEmpty else { return nil }
        return Array(index.words(forTurnAt: position))
    }

    /// Markers this turn can draw among its own words. Empty for an edited
    /// turn and for jobs merged before word timings were retained, both of
    /// which fall back to the row form.
    public func placedMarkers(at position: Int) -> [MarkerPlacement.Placed] {
        placements[position] ?? []
    }

    /// Markers flagged since the previous turn started that no turn could
    /// place inline.
    public func rowMarkers(beforeTurnAt position: Int) -> [Transcript.Marker] {
        guard let transcript, let markers = transcript.markers, !markers.isEmpty,
              position < transcript.turns.count else { return [] }
        let lowerBound = position == 0 ? -.infinity : transcript.turns[position - 1].start
        let start = transcript.turns[position].start
        return markers.filter { $0.time > lowerBound && $0.time <= start && !inlineMarkerIDs.contains($0.id) }
    }

    /// Flagged after the last turn began and not placed inline. Drawn after the
    /// last turn, or they vanish.
    public var trailingRowMarkers: [Transcript.Marker] {
        guard let transcript, let markers = transcript.markers, !markers.isEmpty else { return [] }
        let trailing = transcript.turns.last.map { last in markers.filter { $0.time > last.start } } ?? markers
        return trailing.filter { !inlineMarkerIDs.contains($0.id) }
    }

    /// A row marker cannot show where it landed, so it quotes the surrounding
    /// words instead.
    public func rowMarkerLabel(_ marker: Transcript.Marker, at position: Int?) -> String {
        if let label = marker.label { return label }
        let stamp = "Marked at " + TranscriptClock.label(marker.time)
        if let position,
           let quote = MarkerPlacement.context(around: marker, in: Array(index.words(forTurnAt: position))) {
            return "\(stamp) · “\(quote)”"
        }
        return stamp
    }

    private func placeMarkers() {
        placements = [:]
        inlineMarkerIDs = []
        guard let transcript, let markers = transcript.markers, !markers.isEmpty else { return }
        for (position, turn) in transcript.turns.enumerated() where turn.edited != true {
            let placed = MarkerPlacement.place(markers, in: Array(index.words(forTurnAt: position)))
            guard !placed.isEmpty else { continue }
            placements[position] = placed
            inlineMarkerIDs.formUnion(placed.map(\.marker.id))
        }
    }

    // MARK: - Corrections

    /// Corrections live in the overlay, never in `transcript.json`, so a
    /// re-merge cannot lose them.
    public func edit(_ turn: Transcript.Turn, to newText: String) throws {
        try JobPipeline.editTurnText(files: files, turn: turn, newText: newText)
        load()
    }

    public func revertEdit(_ turn: Transcript.Turn) throws {
        try JobPipeline.clearTurnEdit(files: files, turn: turn)
        load()
    }

    /// Reattributes one passage. §9.2: the diarizer's own claim is left in
    /// place, so centroid lookup and enrollment still read machine output.
    public func reassign(_ turn: Transcript.Turn, to cluster: String, displayName: String? = nil) throws {
        try JobPipeline.assignTurn(files: files, turn: turn, toCluster: cluster, displayName: displayName)
        load()
    }

    /// The minted cluster has no centroid behind it, so `canEnroll` refuses
    /// to enrol it: an invented speaker is a label, not a voiceprint.
    public func assignToNewSpeaker(_ turn: Transcript.Turn, named name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try reassign(turn, to: UserOverlay.mintSpeakerCluster(), displayName: trimmed)
    }

    public func rename(cluster: String, to newName: String) throws {
        try JobPipeline.relabelSpeaker(files: files, cluster: cluster, newName: newName)
        load()
    }

    /// One tap of an "auto" chip: the §13.1 "the user said" bit flips.
    public func confirm(cluster: String) throws {
        try JobPipeline.confirmSpeaker(files: files, cluster: cluster)
        load()
    }

    public func canEnroll(cluster: String) -> Bool {
        guard cluster != "UNKNOWN", let transcript,
              let diarization = try? AtomicFile.readJSON(DiarizationResult.self, from: files.diarization, stage: "DIARIZED"),
              diarization.centroids?[cluster] != nil else { return false }
        let clusterTurns = transcript.turns.filter { $0.cluster == cluster }
        return SpeakerMatcher.isCleanForEnrollment(clusterTurns: clusterTurns)
    }

    public func enrollVoice(cluster: String, as name: String) {
        guard let diarization = try? AtomicFile.readJSON(DiarizationResult.self, from: files.diarization, stage: "DIARIZED"),
              let centroid = diarization.centroids?[cluster] else { return }
        SpeakerProfileStore.enroll(displayName: name, embedding: centroid,
                                   modelIdentifier: diarization.modelIdentifier)
    }
}

/// Clock labels for turns, markers and the playback bar: minutes and seconds,
/// with hours only once a recording reaches them. The Mac printed 65:00 where
/// iOS printed 1:05:00.
public enum TranscriptClock {
    public static func label(_ time: TimeInterval) -> String {
        let total = Int(max(0, time))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    public static func rateLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.2g×", rate)
    }
}
