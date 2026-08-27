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

    public init(version: Int = UserOverlay.currentVersion,
                speakerNames: [String: SpeakerName] = [:],
                turnEdits: [TurnEdit] = [],
                speakerRanges: [SpeakerRange] = [],
                markers: [Transcript.Marker] = []) {
        self.version = version
        self.speakerNames = speakerNames
        self.turnEdits = turnEdits
        self.speakerRanges = speakerRanges
        self.markers = markers
    }

    public var isEmpty: Bool {
        speakerNames.isEmpty && turnEdits.isEmpty && speakerRanges.isEmpty && markers.isEmpty
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

        if !markers.isEmpty {
            result.markers = markers.sorted { $0.time < $1.time }
        }
        return ApplyResult(transcript: result, staleEdits: stale)
    }

    public func apply(to transcript: Transcript) -> Transcript {
        applyReportingStale(to: transcript).transcript
    }

    /// The nearest turn in the same cluster whose start is within tolerance.
    static func turnIndex(for edit: TurnEdit, in turns: [Transcript.Turn]) -> Int? {
        var best: (index: Int, distance: TimeInterval)?
        for (index, turn) in turns.enumerated() where turn.cluster == edit.cluster {
            let distance = abs(turn.start - edit.start)
            guard distance <= anchorTolerance else { continue }
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
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
        markers.append(Transcript.Marker(time: time, label: label))
        markers.sort { $0.time < $1.time }
    }
}
