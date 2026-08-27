import SwiftUI
import LonghandKit

/// Where the processing time went, so a slow job is a measurement rather than
/// a suspicion. Collapsed by default: it answers a question most readings of a
/// transcript are not asking.
public struct ProcessingTimings: View {
    public let record: JobRecord
    /// The engine that produced the words, named under the breakdown.
    public var asrModel: String?

    public init(record: JobRecord, asrModel: String? = nil) {
        self.record = record
        self.asrModel = asrModel
    }

    static let order = JobStage.pipelineOrder

    public static func durationText(_ seconds: TimeInterval) -> String {
        StageBudget.durationText(seconds)
    }

    public var body: some View {
        if let total = record.totalProcessingSeconds, total > 0 {
            let overran = Set(StageBudget.implausibleStages(in: record))
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Self.order, id: \.self) { stage in
                        if let seconds = record.stageSeconds?[stage.rawValue], seconds >= 0.05 {
                            HStack {
                                Text(JobPipeline.stageDisplayName(stage))
                                Spacer()
                                Text(Self.durationText(seconds))
                                    .monospacedDigit()
                                    .foregroundStyle(overran.contains(stage) ? Color.orange : Color.secondary)
                            }
                        }
                    }
                    if record.wasResumed {
                        // The totals above are a sum over sittings, and a stage
                        // that ran again is counted each time. True, and worth
                        // labelling: unlabelled it reads as one run's cost.
                        Text("Totals across \(record.processingRuns ?? 1) runs. A stage that ran again is counted each time.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("timing-resumed")
                    }
                    if !overran.isEmpty {
                        // A measurement, not a verdict: the transcript is fine,
                        // and the reader is told what the number means rather
                        // than being handed a colour to interpret.
                        Text(overran.count == 1
                             ? "\(JobPipeline.stageDisplayName(overran.first!)) took far longer than that stage should need. The transcript is unaffected."
                             : "Some stages took far longer than they should need. The transcript is unaffected.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("timing-anomaly")
                    }
                    if let asrModel {
                        Divider()
                        Text(asrModel).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .padding(.top, 4)
            } label: {
                Label(record.wasResumed
                      ? "Processed in \(Self.durationText(total)) across \(record.processingRuns ?? 1) runs"
                      : "Processed in \(Self.durationText(total))",
                      systemImage: overran.isEmpty ? "stopwatch" : "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(overran.isEmpty ? Color.secondary : Color.orange)
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("processing-timings")
        }
    }
}

/// The passages the §6.4 hallucination filter removed, with what they said and
/// when.
///
/// The degradation on the record says a passage was filtered; this says which,
/// which is the difference between a warning and something the owner can act
/// on. `10_asr.json` has held these spans all along precisely so the behaviour
/// would be auditable, and until now nothing read them back.
///
/// Collapsed by default, and worded as a report rather than a warning: the
/// filter is usually right, and a reader who can see the text can tell.
public struct SuppressedSpans: View {
    public let spans: [SuppressedSpan]

    public init(spans: [SuppressedSpan]) {
        self.spans = spans
    }

    /// Plain language for a `Reason`. The raw cases are for switching on, not
    /// for reading, in the same spirit as `Degradation.Kind`.
    public nonisolated static func reasonText(_ reason: SuppressedSpan.Reason) -> String {
        switch reason {
        case .lowLogprobInSilence: "uncertain, and over silence"
        case .boilerplateInSilence: "stock phrase over silence"
        case .verbatimRepeat: "repeat of the line before"
        case .repetitionTail: "runaway repetition"
        }
    }

    static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    public var body: some View {
        if !spans.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(Self.timecode(span.start)).monospacedDigit()
                                Spacer()
                                Text(Self.reasonText(span.reason))
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            // The words themselves, so a wrongly filtered line
                            // is recognizable as one.
                            Text(span.text)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("Re-transcribing does not keep these. They are shown so a passage the filter took by mistake is visible rather than lost.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } label: {
                Label(spans.count == 1
                      ? "1 passage filtered as likely hallucination"
                      : "\(spans.count) passages filtered as likely hallucination",
                      systemImage: "text.badge.minus")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("suppressed-spans")
        }
    }
}

public extension SuppressedSpans {
    /// Reads just the spans out of `10_asr.json`.
    ///
    /// Decoded through a one-key shape rather than `ASRResult` so an hour-long
    /// job does not have to materialize every segment and every word to answer
    /// a question about a handful of removed passages. A file that will not
    /// decode yields no spans rather than an error: this is a footnote on a
    /// transcript, and it must not be able to take the screen down.
    ///
    /// `nonisolated` because it is file I/O, not view work: the extension would
    /// otherwise inherit `View`'s main-actor isolation and force every caller,
    /// tests included, through an await for a synchronous read.
    nonisolated static func load(from files: JobFiles) -> [SuppressedSpan] {
        struct SpansOnly: Decodable { var suppressedSpans: [SuppressedSpan]? }
        guard let data = try? Data(contentsOf: files.asr),
              let decoded = try? JSONDecoder().decode(SpansOnly.self, from: data) else { return [] }
        return decoded.suppressedSpans ?? []
    }
}

/// What a finished job with no turns can still say about why. Degradations
/// answer "did something break"; the gain and the input level answer "did the
/// microphone hear anything at all", which is the question being asked.
public struct NoSpeechDiagnostics: View {
    public let degradations: [Degradation]
    public let appliedGainDb: Double?
    public let inputLevelDbFS: Double?

    public init(degradations: [Degradation], appliedGainDb: Double?, inputLevelDbFS: Double?) {
        self.degradations = degradations
        self.appliedGainDb = appliedGainDb
        self.inputLevelDbFS = inputLevelDbFS
    }

    public var body: some View {
        VStack(spacing: 8) {
            ForEach(degradations, id: \.self) { Text($0.message) }
            if let appliedGainDb {
                Text("The recording was boosted by \(Int(appliedGainDb.rounded())) dB and still had no recognizable speech.")
            }
            if let inputLevelDbFS {
                Text(inputLevelDbFS < -45
                     ? "Input level was \(Int(inputLevelDbFS.rounded())) dBFS, close to silence, so the microphone probably captured nothing. Play it back to check."
                     : "Input level was \(Int(inputLevelDbFS.rounded())) dBFS, so the microphone did capture sound. Play it back to hear what.")
            }
        }
    }
}

/// The §5.4 import stats a transcript screen shows when there is nothing to
/// show. Read once, on load, by whichever shell is asking.
public struct ImportDiagnostics: Sendable {
    public var location: CapturedLocation?
    public var appliedGainDb: Double?
    public var inputLevelDbFS: Double?

    public init(metadata: ImportMetadata?) {
        location = metadata?.location
        appliedGainDb = metadata?.appliedGainDb
        // Linear RMS per channel (§5.4 stats) to dBFS, loudest channel.
        inputLevelDbFS = (metadata?.channelRMSEnergy ?? []).max().flatMap {
            $0 > 0 ? 20 * log10($0) : nil
        }
    }
}
