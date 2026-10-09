import Foundation

/// Everything the user authored about a job: speaker names, text corrections,
/// per-turn speaker reassignments, and markers.
///
/// The rule this type exists to enforce: `transcript.json` and every export are
/// a pure function of the merged words, the identity checkpoint, and this
/// overlay. Derived data never stores user intent, so a re-merge can rebuild
/// the transcript from scratch without losing anything a person typed, which is
/// what §10's `COMPLETE → MERGED` re-entry edge implies.
public struct UserOverlay: Codable, Sendable, Equatable {

    public static let currentVersion = 1

    /// Anchors match a turn whose start is within this of the recorded one.
    /// Re-merges move boundaries by tens of milliseconds; a quarter second is
    /// the tolerance the merge itself uses for τ (§8).
    public static let anchorTolerance: TimeInterval = 0.25

    /// Namespace for speakers the user introduced, kept distinct from the
    /// diarizer's `SPEAKER_NN` keys so nothing downstream mistakes an invented
    /// speaker for one with a voice signature behind it: centroid lookup and
    /// enrollment both key off the diarization checkpoint, which never holds
    /// one of these.
    public static let userClusterPrefix = "USER_"

    public static func isUserDefined(cluster: String) -> Bool {
        cluster.hasPrefix(userClusterPrefix)
    }

    /// Random rather than sequential: two devices editing the same job would
    /// otherwise both mint `USER_1` for different people.
    public static func mintSpeakerCluster() -> String {
        userClusterPrefix + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
    }

    public var version: Int
    /// Applied last, so it always beats an automatic match (§13.1).
    public var speakerNames: [String: SpeakerName]
    public var turnEdits: [TurnEdit]
    public var speakerRanges: [SpeakerRange]
    public var markers: [Transcript.Marker]
    /// Turns the user cut in two. Applied first: everything else anchors on
    /// the turns that result.
    public var turnSplits: [TurnSplit]

    public init(version: Int = UserOverlay.currentVersion,
                speakerNames: [String: SpeakerName] = [:],
                turnEdits: [TurnEdit] = [],
                speakerRanges: [SpeakerRange] = [],
                markers: [Transcript.Marker] = [],
                turnSplits: [TurnSplit] = []) {
        self.version = version
        self.speakerNames = speakerNames
        self.turnEdits = turnEdits
        self.speakerRanges = speakerRanges
        self.markers = markers
        self.turnSplits = turnSplits
    }

    private enum CodingKeys: String, CodingKey {
        case version, speakerNames, turnEdits, speakerRanges, markers, turnSplits
    }

    /// Every list is optional on the way in: an overlay written before a
    /// list existed must keep decoding, or every export of that job fails.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? UserOverlay.currentVersion
        speakerNames = try container.decodeIfPresent([String: SpeakerName].self, forKey: .speakerNames) ?? [:]
        turnEdits = try container.decodeIfPresent([TurnEdit].self, forKey: .turnEdits) ?? []
        speakerRanges = try container.decodeIfPresent([SpeakerRange].self, forKey: .speakerRanges) ?? []
        markers = try container.decodeIfPresent([Transcript.Marker].self, forKey: .markers) ?? []
        turnSplits = try container.decodeIfPresent([TurnSplit].self, forKey: .turnSplits) ?? []
    }

    public var isEmpty: Bool {
        speakerNames.isEmpty && turnEdits.isEmpty && speakerRanges.isEmpty && markers.isEmpty
            && turnSplits.isEmpty
    }

    // MARK: - Entries

    public struct SpeakerName: Codable, Sendable, Equatable {
        public var displayName: String
        /// A user statement about identity, as opposed to a model match (§9.3).
        public var confirmed: Bool

        public init(displayName: String, confirmed: Bool = true) {
            self.displayName = displayName
            self.confirmed = confirmed
        }
    }

    /// A corrected passage, anchored on `start` + cluster. Never `Turn.id`,
    /// which is positional and renumbers when a turn is added above it, and
    /// never `end`, which a join or a split moves while `start` holds. The
    /// hash then confirms it is the same words.
    public struct TurnEdit: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var start: TimeInterval
        public var cluster: String
        /// `StableHash.hex(TextFold.foldForHash(originalText))` at edit time.
        public var baseTextHash: String
        public var newText: String
        public var editedAt: Date

        public init(id: UUID = UUID(), start: TimeInterval, cluster: String,
                    baseTextHash: String, newText: String, editedAt: Date = Date()) {
            self.id = id
            self.start = start
            self.cluster = cluster
            self.baseTextHash = baseTextHash
            self.newText = newText
            self.editedAt = editedAt
        }

        public static func hash(of text: String) -> String {
            StableHash.hex(TextFold.foldForHash(text))
        }
    }

    /// Time-ranged and hash-free, so it survives both splits (each fragment
    /// inherits) and joins (the joined turn inherits if its midpoint lands
    /// inside).
    public struct SpeakerRange: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var start: TimeInterval
        public var end: TimeInterval
        /// Cluster to attribute the turn to. May name a cluster the diarizer
        /// found elsewhere in the recording.
        public var cluster: String
        /// Name to show when the cluster has no entry of its own.
        public var displayName: String?

        public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval,
                    cluster: String, displayName: String? = nil) {
            self.id = id
            self.start = start
            self.end = end
            self.cluster = cluster
            self.displayName = displayName
        }

        func covers(_ turn: Transcript.Turn) -> Bool {
            let midpoint = (turn.start + turn.end) / 2
            // `end` is exclusive, so a zero-length range would match nothing,
            // including the degenerate turn it was recorded for.
            guard end > start else { return abs(midpoint - start) <= UserOverlay.anchorTolerance }
            return midpoint >= start && midpoint < end
        }
    }

    /// A turn cut in two at a word. Anchored like an edit, on the turn's
    /// start and cluster; the cut itself is a word index into the turn's
    /// text (which is its words joined by spaces) and the time that word
    /// starts, which becomes the second half's start. The index is what
    /// makes the cut reproducible on the text; the time is what makes the
    /// halves findable afterwards.
    public struct TurnSplit: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var start: TimeInterval
        public var cluster: String
        /// The first word of the second half.
        public var wordIndex: Int
        public var atTime: TimeInterval

        public init(id: UUID = UUID(), start: TimeInterval, cluster: String,
                    wordIndex: Int, atTime: TimeInterval) {
            self.id = id
            self.start = start
            self.cluster = cluster
            self.wordIndex = wordIndex
            self.atTime = atTime
        }
    }

    // MARK: - Application

    /// Why an edit did not land, so the UI can say so (§17).
    public enum StaleReason: String, Sendable {
        /// No turn starts near this time in this cluster any more.
        case noMatchingTurn
        /// The turn is there, but the words underneath changed.
        case textChanged
    }

    public struct ApplyResult: Sendable {
        public var transcript: Transcript
        /// Edits that could not be reattached, newest first in overlay order.
        public var staleEdits: [(edit: TurnEdit, reason: StaleReason)]

        public var staleCount: Int { staleEdits.count }
    }

    /// Pure, and idempotent: an edit whose target already holds `newText`
    /// counts as applied rather than stale, so re-running the pipeline over an
    /// already-overlaid transcript is safe.
    public func applyReportingStale(to transcript: Transcript) -> ApplyResult {
        var result = transcript
        var stale: [(TurnEdit, StaleReason)] = []

        // 0. Splits, before anything that anchors on a turn: the halves are
        //    the turns the rest of the overlay was written against. A split
        //    that no longer fits (a re-merge moved the words) is skipped.
        if !turnSplits.isEmpty {
            result.turns = Self.applySplits(turnSplits, to: result.turns)
        }

        // 1. Speaker reassignment first: it decides which cluster a turn
        //    belongs to, and therefore which name it should show.
        if !speakerRanges.isEmpty {
            for index in result.turns.indices {
                guard let range = speakerRanges.last(where: { $0.covers(result.turns[index]) }) else { continue }
                result.turns[index].assignedCluster = range.cluster
                if result.speakers[range.cluster] == nil, let name = range.displayName {
                    result.speakers[range.cluster] = .init(displayName: name, confirmedByUser: true)
                }
            }
        }

        // 2. Names: the user's word beats any automatic match.
        for (cluster, name) in speakerNames {
            let existing = result.speakers[cluster]
            result.speakers[cluster] = .init(displayName: name.displayName,
                                             matchScore: existing?.matchScore,
                                             confirmedByUser: name.confirmed ? true : existing?.confirmedByUser)
        }

        // 3. Resolve the denormalized per-turn name from the table, so exports
        //    (which read `turn.speaker`) cannot disagree with it.
        for index in result.turns.indices {
            let cluster = result.turns[index].effectiveCluster
            // Keep what the turn carries when the cluster has no entry: that is
            // UNKNOWN, whose name is "Unknown speaker". Falling back to the key
            // would print a machine identifier into every export.
            result.turns[index].speaker = result.speakers[cluster]?.displayName ?? result.turns[index].speaker
        }

        // 4. Text edits.
        for edit in turnEdits {
            guard let index = Self.turnIndex(for: edit, in: result.turns) else {
                stale.append((edit, .noMatchingTurn))
                continue
            }
            let current = result.turns[index].text
            if TurnEdit.hash(of: current) == edit.baseTextHash {
                result.turns[index].text = edit.newText
                result.turns[index].edited = true
            } else if current == edit.newText {
                // Already applied (a second pass over the same transcript).
                result.turns[index].edited = true
            } else {
                stale.append((edit, .textChanged))
            }
        }

        // Unconditional: the overlay is the only source of markers, so an
        // empty list means none, not "keep what the transcript had". Gated
        // on non-empty, deleting the last marker left it in transcript.json
        // and on every screen that reads it.
        result.markers = markers.isEmpty ? nil : markers.sorted { $0.time < $1.time }
        return ApplyResult(transcript: result, staleEdits: stale)
    }

    public func apply(to transcript: Transcript) -> Transcript {
        applyReportingStale(to: transcript).transcript
    }

    /// The nearest turn in the same cluster whose start is within tolerance.
    static func turnIndex(for edit: TurnEdit, in turns: [Transcript.Turn]) -> Int? {
        turnIndex(start: edit.start, cluster: edit.cluster, in: turns)
    }

    static func turnIndex(start: TimeInterval, cluster: String, in turns: [Transcript.Turn]) -> Int? {
        var best: (index: Int, distance: TimeInterval)?
        for (index, turn) in turns.enumerated() where turn.cluster == cluster {
            let distance = abs(turn.start - start)
            guard distance <= anchorTolerance else { continue }
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    /// Cuts turns where the splits say. Two splits of one original turn are
    /// applied from the later word to the earlier, so each index still
    /// counts from the original start when its turn comes. Ids are
    /// renumbered after, since they are positional.
    static func applySplits(_ splits: [TurnSplit], to turns: [Transcript.Turn]) -> [Transcript.Turn] {
        var turns = turns
        let ordered = splits.sorted {
            $0.start != $1.start ? $0.start < $1.start : $0.wordIndex > $1.wordIndex
        }
        for split in ordered {
            guard let index = turnIndex(start: split.start, cluster: split.cluster, in: turns) else { continue }
            let turn = turns[index]
            // A split lands on the first half of an earlier split of the same
            // turn, whose start is the same; its text is what is left.
            let words = turn.text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard split.wordIndex > 0, split.wordIndex < words.count,
                  split.atTime > turn.start, split.atTime < turn.end else { continue }
            var first = turn
            first.text = words[..<split.wordIndex].joined(separator: " ")
            first.end = split.atTime
            var second = turn
            second.text = words[split.wordIndex...].joined(separator: " ")
            second.start = split.atTime
            second.splitFromPrevious = true
            turns.replaceSubrange(index...index, with: [first, second])
        }
        for index in turns.indices { turns[index].id = index }
        return turns
    }

    // MARK: - Mutation

    /// Records a correction, replacing any earlier edit of the same passage.
    /// The anchor hash has to describe the machine's text: callers hand in a
    /// turn read back from transcript.json, which already has the overlay
    /// applied, so re-hashing it would anchor the new edit to the previous
    /// correction and the next rerender would match neither.
    public mutating func setText(_ newText: String, forTurn turn: Transcript.Turn) {
        let existing = turnEdits.first { abs($0.start - turn.start) <= Self.anchorTolerance && $0.cluster == turn.cluster }
        turnEdits.removeAll { abs($0.start - turn.start) <= Self.anchorTolerance && $0.cluster == turn.cluster }
        // Carried forward when re-editing; only a first edit sees machine text.
        let baseHash = existing?.baseTextHash ?? TurnEdit.hash(of: turn.text)
        // Editing back to the machine's own words is an un-edit, not an edit.
        guard TurnEdit.hash(of: newText) != baseHash else { return }
        turnEdits.append(TurnEdit(start: turn.start, cluster: turn.cluster,
                                  baseTextHash: baseHash, newText: newText))
    }

    /// Drops the correction covering this turn, restoring the derived text.
    public mutating func clearText(forTurn turn: Transcript.Turn) {
        turnEdits.removeAll { abs($0.start - turn.start) <= Self.anchorTolerance && $0.cluster == turn.cluster }
    }

    public mutating func setSpeakerName(_ displayName: String, forCluster cluster: String, confirmed: Bool = true) {
        speakerNames[cluster] = SpeakerName(displayName: displayName, confirmed: confirmed)
    }

    public mutating func assign(turn: Transcript.Turn, toCluster cluster: String, displayName: String? = nil) {
        // Every range of a user-defined cluster carries the name, since that
        // is the only place it is recorded and `apply` seeds the speakers table
        // from whichever range it meets. Undoing the first range would
        // otherwise leave the cluster nameless.
        let name = displayName
            ?? speakerNames[cluster]?.displayName
            ?? speakerRanges.first { $0.cluster == cluster }?.displayName
        speakerRanges.removeAll { $0.covers(turn) }
        if cluster != turn.cluster {   // otherwise: back to the diarizer's own claim
            speakerRanges.append(SpeakerRange(start: turn.start, end: turn.end,
                                              cluster: cluster, displayName: name))
        }
        pruneOrphanedUserSpeakers()
    }

    /// Drops the name of a user-defined speaker whose last passage was
    /// reassigned away; that cluster appears nowhere in the transcript now.
    private mutating func pruneOrphanedUserSpeakers() {
        let live = Set(speakerRanges.map(\.cluster))
        speakerNames = speakerNames.filter {
            !Self.isUserDefined(cluster: $0.key) || live.contains($0.key)
        }
    }

    public mutating func addMarker(at time: TimeInterval, label: String? = nil) {
        markers.append(Transcript.Marker(time: max(0, time), label: Self.cleanedLabel(label)))
        markers.sort { $0.time < $1.time }
    }

    /// Markers made while recording, flags and typed notes alike. A note is a
    /// marker with a label: the transcript draws it at the moment it was
    /// typed, among the words being said. Blank labels become plain flags.
    public mutating func addMarkers(_ new: [Transcript.Marker]) {
        for marker in new {
            markers.append(Transcript.Marker(id: marker.id, time: marker.time,
                                             label: Self.cleanedLabel(marker.label)))
        }
        markers.sort { $0.time < $1.time }
    }

    /// Relabels or moves a marker. A marker is identified by its id, which
    /// the overlay minted and the transcript carries, so an edit made from
    /// the transcript screen finds the right one even when two share a
    /// second. Nil leaves that field alone; a blank label makes it a flag.
    @discardableResult
    public mutating func updateMarker(id: UUID, label: String?? = nil, time: TimeInterval? = nil) -> Bool {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return false }
        if let label { markers[index].label = Self.cleanedLabel(label) }
        if let time { markers[index].time = max(0, time) }
        markers.sort { $0.time < $1.time }
        return true
    }

    @discardableResult
    public mutating func removeMarker(id: UUID) -> Bool {
        let before = markers.count
        markers.removeAll { $0.id == id }
        return markers.count < before
    }

    // MARK: - Splits

    /// Cuts `turn` so that word `wordIndex` (counting from 0 in the turn's
    /// text) begins a new turn starting at `atTime`. The turn passed in is
    /// one read back from transcript.json. Refuses the ends: a split there
    /// is a no-op.
    ///
    /// A turn that is itself the second half of an earlier split has no
    /// anchor of its own: its words are the parent's from the parent's
    /// `wordIndex` on, so the new cut is recorded on the parent's anchor at
    /// the parent's index plus this one, which is what `applySplits` replays.
    @discardableResult
    public mutating func split(turn: Transcript.Turn, atWordIndex wordIndex: Int, atTime: TimeInterval) -> Bool {
        let wordCount = turn.text.split(separator: " ", omittingEmptySubsequences: false).count
        guard wordIndex > 0, wordIndex < wordCount, atTime > turn.start, atTime < turn.end else { return false }
        if let parent = turnSplits.first(where: {
            $0.cluster == turn.cluster && abs($0.atTime - turn.start) <= Self.anchorTolerance
        }) {
            turnSplits.append(TurnSplit(start: parent.start, cluster: turn.cluster,
                                        wordIndex: parent.wordIndex + wordIndex, atTime: atTime))
        } else {
            turnSplits.append(TurnSplit(start: turn.start, cluster: turn.cluster,
                                        wordIndex: wordIndex, atTime: atTime))
        }
        return true
    }

    /// Rejoins a turn with the one before it by dropping the split that made
    /// it. Nothing happens for a turn no split produced.
    @discardableResult
    public mutating func join(turn: Transcript.Turn) -> Bool {
        guard let index = turnSplits.firstIndex(where: {
            $0.cluster == turn.cluster && abs($0.atTime - turn.start) <= Self.anchorTolerance
        }) else { return false }
        turnSplits.remove(at: index)
        return true
    }

    static func cleanedLabel(_ label: String?) -> String? {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.flatMap { $0.isEmpty ? nil : $0 }
    }
}
