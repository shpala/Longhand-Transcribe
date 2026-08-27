import Foundation

/// Turns the corrections already in the library into a measurement.
///
/// §18.1's accuracy harness was deferred for want of an annotated corpus. One
/// has been accumulating the whole time: every `UserOverlay.TurnEdit` holds
/// `baseTextHash`, the machine's own words, beside `newText`, what a person
/// changed them to. The machine text itself is recoverable by rebuilding turns
/// from `30_merged_words.json`, exactly as `rerender` does, and the stored hash
/// confirms the pair is genuine rather than a coincidence of timing.
///
/// **What this can and cannot say.** It sees only the turns someone bothered to
/// correct, so it is biased towards hard passages and cannot produce an
/// absolute WER for a recording. Two things it can do: compare models or
/// periods over the same corrections, and put a floor under the error rate,
/// since a word a person changed was definitely wrong. Both are stated as such
/// in the report rather than dressed up as a WER for the transcript.
public enum AccuracyCorpus {

    /// One machine/human pair, recovered and verified.
    public struct Pair: Sendable, Equatable {
        public let jobID: String
        public let language: String?
        public let asrModel: String?
        public let start: TimeInterval
        public let machine: String
        public let human: String
        public var counts: WordAlignment.Counts {
            WordAlignment.compare(machine: machine, human: human)
        }
    }

    /// Why an edit could not be turned into a pair. Counted and reported: a
    /// harness that silently drops its inputs is measuring an unknown subset.
    public enum Skip: String, Sendable {
        /// No turn starts near this time in this cluster any more.
        case noMatchingTurn
        /// A turn is there and the words underneath have changed since, so the
        /// hash no longer proves what the machine said at edit time.
        case machineTextChanged
        /// The correction matched the machine's own words after folding, so
        /// there is no error to measure. Punctuation-only edits land here.
        case noMeasurableDifference
    }

    public struct JobResult: Sendable {
        public var jobID: String
        public var language: String?
        public var asrModel: String?
        /// Turns in the rebuilt transcript, corrected or not.
        public var totalTurns: Int
        /// Words the machine produced across the whole recording.
        public var totalMachineWords: Int
        public var pairs: [Pair]
        public var skipped: [Skip: Int]

        public var counts: WordAlignment.Counts {
            pairs.reduce(WordAlignment.Counts()) { $0 + $1.counts }
        }

        /// Errors as a share of every word the machine produced, not just the
        /// corrected ones. A genuine floor: the numerator counts only words a
        /// person actually changed, so the true rate cannot be lower.
        public var errorFloor: Double? {
            guard totalMachineWords > 0 else { return nil }
            return Double(counts.errors) / Double(totalMachineWords)
        }

        public var correctedTurnShare: Double? {
            guard totalTurns > 0 else { return nil }
            return Double(pairs.count) / Double(totalTurns)
        }
    }

    /// Rebuilds a job's machine text and pairs it with the corrections.
    ///
    /// `transcript.json` is deliberately not the source: it has the overlay
    /// applied, so its turns are already the corrected text and pairing them
    /// with the corrections would measure nothing.
    public static func pairs(inJobAt root: URL) -> JobResult? {
        let files = JobFiles(root: root)
        guard let merged = (try? AtomicFile.readJSON(MergeOutput.self,
                                                     from: files.mergedWords, stage: "MERGED")) ?? nil
        else { return nil }

        let record = (try? AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job")) ?? nil
        let transcript = (try? AtomicFile.readJSON(Transcript.self,
                                                   from: files.transcriptJSON, stage: "COMPLETE")) ?? nil
        let overlay = ((try? AtomicFile.readJSON(UserOverlay.self,
                                                 from: files.overlay, stage: "overlay")) ?? nil) ?? UserOverlay()

        let raw = TurnBuilder.buildTurns(words: merged.words, params: merged.params)
        let machineTurns = TurnBuilder.transcriptTurns(from: raw, speakers: [:])

        var result = JobResult(jobID: root.lastPathComponent,
                               language: record?.language,
                               asrModel: transcript?.models.asr,
                               totalTurns: machineTurns.count,
                               totalMachineWords: machineTurns.reduce(0) {
                                   $0 + WordAlignment.tokens($1.text).count
                               },
                               pairs: [],
                               skipped: [:])

        for edit in overlay.turnEdits {
            guard let index = UserOverlay.turnIndex(for: edit, in: machineTurns) else {
                result.skipped[.noMatchingTurn, default: 0] += 1
                continue
            }
            let machine = machineTurns[index].text
            guard UserOverlay.TurnEdit.hash(of: machine) == edit.baseTextHash else {
                result.skipped[.machineTextChanged, default: 0] += 1
                continue
            }
            let counts = WordAlignment.compare(machine: machine, human: edit.newText)
            guard counts.errors > 0 else {
                result.skipped[.noMeasurableDifference, default: 0] += 1
                continue
            }
            result.pairs.append(Pair(jobID: result.jobID,
                                     language: result.language,
                                     asrModel: result.asrModel,
                                     start: edit.start,
                                     machine: machine,
                                     human: edit.newText))
        }
        return result
    }

    /// Every job folder directly under `root` that has a merge checkpoint.
    public static func scan(libraryAt root: URL) -> [JobResult] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { pairs(inJobAt: $0) }
    }

    // MARK: - Grouping

    /// Aggregated over whatever key the caller is comparing: the ASR model, the
    /// language, a month. Comparison is the only thing these numbers support,
    /// so grouping is the primary operation rather than an afterthought.
    public struct Group: Sendable {
        public var key: String
        public var jobs: Int
        public var counts: WordAlignment.Counts
        public var totalMachineWords: Int
        public var totalTurns: Int
        public var correctedTurns: Int

        public var errorFloor: Double? {
            totalMachineWords > 0 ? Double(counts.errors) / Double(totalMachineWords) : nil
        }
    }

    public static func grouped(_ results: [JobResult],
                               by key: @Sendable (JobResult) -> String) -> [Group] {
        var groups: [String: Group] = [:]
        for result in results {
            let name = key(result)
            var group = groups[name] ?? Group(key: name, jobs: 0, counts: WordAlignment.Counts(),
                                              totalMachineWords: 0, totalTurns: 0, correctedTurns: 0)
            group.jobs += 1
            group.counts = group.counts + result.counts
            group.totalMachineWords += result.totalMachineWords
            group.totalTurns += result.totalTurns
            group.correctedTurns += result.pairs.count
            groups[name] = group
        }
        return groups.values.sorted { $0.key < $1.key }
    }
}
