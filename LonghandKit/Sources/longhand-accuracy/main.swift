import Foundation
import LonghandKit

// Reads a pulled library (`$D pull device build/recs`) and reports what the
// corrections in it say about transcription quality. Deliberately a command
// rather than a screen: it is a developer's measurement, not a user's feature,
// and §14.1 keeps the corpus on the device until someone pulls it deliberately.

let arguments = CommandLine.arguments.dropFirst()
guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else {
    FileHandle.standardError.write(Data("""
    usage: longhand-accuracy <recordings-dir> [--by model|language|job] [--pairs]
           longhand-accuracy <recordings-dir> --calibration

      <recordings-dir>  A pulled Documents/Recordings, one folder per job.
      --by              What to group the comparison by. Default: model.
      --pairs           Print every machine/human pair, worst first.
      --calibration     §18.2 speaker-matcher calibration, over the clusters
                        whose names you confirmed.

    """.utf8))
    exit(2)
}

let root = URL(fileURLWithPath: path)

if arguments.contains("--calibration") {
    exit(CalibrationCommand.run(libraryAt: root))
}
let groupBy = arguments.firstIndex(of: "--by").map { index -> String in
    let next = arguments.index(after: index)
    return next < arguments.endIndex ? arguments[next] : "model"
} ?? "model"
let showPairs = arguments.contains("--pairs")

let results = AccuracyCorpus.scan(libraryAt: root)
guard !results.isEmpty else {
    FileHandle.standardError.write(Data("no measurable jobs in \(root.path)\n".utf8))
    exit(1)
}

func percent(_ value: Double?) -> String {
    value.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"
}

let totals = results.reduce(WordAlignment.Counts()) { $0 + $1.counts }
let machineWords = results.reduce(0) { $0 + $1.totalMachineWords }
let turns = results.reduce(0) { $0 + $1.totalTurns }
let corrected = results.reduce(0) { $0 + $1.pairs.count }

print("")
print("Corpus     \(results.count) job\(results.count == 1 ? "" : "s"), \(turns) turns, \(machineWords) machine words")
print("Corrected  \(corrected) turn\(corrected == 1 ? "" : "s") (\(percent(turns > 0 ? Double(corrected) / Double(turns) : nil)) of them)")
print("")

// The headline is the floor, not a WER. Only corrected turns contribute errors,
// so the true rate is at least this and the difference is unmeasured, which the
// label has to carry or the number will be quoted as something it is not.
print("Error floor            \(percent(machineWords > 0 ? Double(totals.errors) / Double(machineWords) : nil))  (\(totals.errors) corrected words of \(machineWords))")
print("Within corrected turns \(percent(totals.errorRate))  substitutions \(totals.substitutions), dropped \(totals.deletions), invented \(totals.insertions)")
print("")

let groups: [AccuracyCorpus.Group]
switch groupBy {
case "language": groups = AccuracyCorpus.grouped(results) { $0.language ?? "unknown" }
case "job": groups = AccuracyCorpus.grouped(results) { $0.jobID }
default: groups = AccuracyCorpus.grouped(results) { $0.asrModel ?? "unknown" }
}

// Padded in Swift rather than through String(format:) and %s: passing
// NSString.utf8String there hands printf a pointer to a temporary that is gone
// by the time it reads it, which segfaults rather than misprinting.
func pad(_ text: String, _ width: Int, left: Bool = true) -> String {
    let padding = String(repeating: " ", count: max(0, width - text.count))
    return left ? text + padding : padding + text
}

let columnWidth = max(24, groups.map(\.key.count).max() ?? 24)
print(pad("by " + groupBy, columnWidth) + pad("jobs", 6, left: false)
      + pad("words", 8, left: false) + pad("floor", 10, left: false)
      + pad("corrected", 12, left: false))
for group in groups {
    print(pad(group.key, columnWidth)
          + pad("\(group.jobs)", 6, left: false)
          + pad("\(group.totalMachineWords)", 8, left: false)
          + pad(percent(group.errorFloor), 10, left: false)
          + pad("\(group.correctedTurns)/\(group.totalTurns)", 12, left: false))
}
print("")

let skips = results.flatMap { $0.skipped }.reduce(into: [AccuracyCorpus.Skip: Int]()) {
    $0[$1.key, default: 0] += $1.value
}
if !skips.isEmpty {
    // A harness that drops inputs silently is measuring an unknown subset.
    print("Not measured: " + skips.sorted { $0.key.rawValue < $1.key.rawValue }
        .map { "\($0.value) \($0.key.rawValue)" }.joined(separator: ", "))
    print("")
}

if showPairs {
    let pairs = results.flatMap(\.pairs).sorted { ($0.counts.errors) > ($1.counts.errors) }
    for pair in pairs {
        let counts = pair.counts
        print("[\(String(format: "%6.1f", pair.start))s] \(counts.errors) error\(counts.errors == 1 ? "" : "s")  \(pair.asrModel ?? "unknown")")
        print("  machine  \(pair.machine)")
        print("  human    \(pair.human)")
    }
    print("")
}

// Said last, where it is read, rather than buried in a doc nobody opens beside
// the numbers it qualifies.
print("""
These figures come only from turns someone corrected, so they are biased
towards hard passages and are not a WER for the recordings. The floor is
sound: a word a person changed was wrong, so the true rate is at least
that. Comparisons between rows are the point; the absolute values are not.
""")
