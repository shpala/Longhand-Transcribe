import Foundation

/// What a stage should plausibly cost, so a pathological one can say so.
///
/// The bounds are deliberately loose. A budget that cries wolf is worse than
/// no budget: it teaches the reader to ignore the one report that mattered.
/// These exist to catch the pathological case, a three-minute "Loading speech
/// model" that was really an unreported download, and not to police the normal
/// variation between a cold phone and a warm Mac.
public enum StageBudget {

    /// Stages whose cost is fixed rather than proportional to the recording,
    /// and which are cheap: rebuilding turns and writing five files are the
    /// work of a moment on any machine.
    ///
    /// `loadingModel` is deliberately absent. It looked like the obvious
    /// candidate, and measurement on an iPhone 16 Pro Max says otherwise: a
    /// first load of the 626 MB turbo weights takes 146 s, while the
    /// pathological run this was written for took 179 s. Thirty seconds apart
    /// is not a threshold, it is noise, and a bound drawn anywhere between them
    /// would call a healthy first load a fault. Core ML compiles for the device
    /// on first load, so minutes are normal there and no honest bound exists.
    static let fixedCostLimits: [JobStage: TimeInterval] = [
        .merging: 60,
        .identifying: 60,
        .exporting: 60,
    ]

    /// Stages that read the whole recording, bounded as a multiple of its
    /// duration. The floor keeps a ten-second voice memo from tripping on
    /// fixed overheads that dwarf its own length.
    static let realtimeFactors: [JobStage: Double] = [
        .preparing: 5,
        .transcribing: 30,
        .diarizing: 20,
    ]

    static let realtimeFloor: TimeInterval = 60

    /// `nil` where no honest bound exists. A download takes as long as the
    /// network takes, and an import is bounded by the copy, not by us.
    public static func limit(for stage: JobStage, recordingSeconds: TimeInterval?) -> TimeInterval? {
        if let fixed = fixedCostLimits[stage] { return fixed }
        guard let factor = realtimeFactors[stage],
              let recordingSeconds, recordingSeconds > 0 else { return nil }
        return Swift.max(realtimeFloor, factor * recordingSeconds)
    }

    public static func isImplausible(stage: JobStage, seconds: TimeInterval,
                                     recordingSeconds: TimeInterval?) -> Bool {
        guard let limit = limit(for: stage, recordingSeconds: recordingSeconds) else { return false }
        return seconds > limit
    }

    /// Every stage of a run that overran its budget, in pipeline order.
    ///
    /// Reads `comparableStageSeconds`, one run's figures, because
    /// `stageSeconds` is a total across sittings: a job resumed enough times
    /// would total past a bound no single run came near, and be called slow for
    /// having been interrupted.
    public static func implausibleStages(in record: JobRecord) -> [JobStage] {
        guard let measured = record.comparableStageSeconds else { return [] }
        return JobStage.pipelineOrder.filter { stage in
            guard let seconds = measured[stage.rawValue] else { return false }
            return isImplausible(stage: stage, seconds: seconds, recordingSeconds: record.duration)
        }
    }

    /// Compact elapsed time. Shared so a failure message and the timings
    /// breakdown cannot describe the same measurement two different ways.
    public static func durationText(_ seconds: TimeInterval) -> String {
        seconds < 60
            ? String(format: "%.1fs", seconds)
            : String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

public extension StageBudget {
    /// Where a single run's time actually went, when one stage dominates it.
    ///
    /// Not a budget: a failure is worth explaining whether or not any stage
    /// misbehaved, and the honest report of "this took three minutes and most
    /// of it was here" needs no threshold to be true.
    static func dominantStage(in thisRun: [JobStage: TimeInterval],
                              minimumShare: Double = 0.5,
                              minimumSeconds: TimeInterval = 5)
        -> (stage: JobStage, seconds: TimeInterval)? {
        let total = thisRun.values.reduce(0, +)
        guard total >= minimumSeconds,
              let busiest = thisRun.max(by: { $0.value < $1.value }),
              busiest.value / total >= minimumShare else { return nil }
        return (busiest.key, busiest.value)
    }

    /// The overrunning stage worth naming: the slowest of them, since that is
    /// where the time actually went.
    static func worstOverrun(in record: JobRecord) -> (stage: JobStage, seconds: TimeInterval)? {
        implausibleStages(in: record)
            .compactMap { stage -> (stage: JobStage, seconds: TimeInterval)? in
                guard let seconds = record.comparableStageSeconds?[stage.rawValue] else { return nil }
                return (stage, seconds)
            }
            .max { $0.seconds < $1.seconds }
    }
}
