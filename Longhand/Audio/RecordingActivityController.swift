@preconcurrency import ActivityKit
import Foundation

/// Puts a take in progress on the Lock Screen and in the Dynamic Island.
///
/// Recording carries on with the screen locked (`UIBackgroundModes: audio`),
/// so without this the only sign of a running microphone is the system's
/// orange dot, and stopping means unlocking and finding the sheet. Updates go
/// out only when something changes: the clock runs on the system's own timer
/// text, so nothing is sent per second.
@MainActor
final class RecordingActivityController {

    private var activity: Activity<RecordingActivityAttributes>?
    private var lastState: RecordingActivityAttributes.ContentState?

    /// Starts one activity per take. Does nothing when the person has turned
    /// Live Activities off for Longhand, which is theirs to decide.
    func start(_ state: RecordingActivityAttributes.ContentState) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(
            attributes: RecordingActivityAttributes(title: "Longhand"),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil)
        lastState = state
    }

    func update(_ state: RecordingActivityAttributes.ContentState) {
        guard let activity, state != lastState else { return }
        lastState = state
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// Gone at once: a saved or discarded take has nothing left to control,
    /// and a lingering card with live-looking buttons would invite a tap that
    /// does nothing.
    func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Takes left behind by a crash or a kill mid-recording. Their microphone
    /// is gone with the process, so they are ended on the next launch.
    static func endOrphans() {
        for activity in Activity<RecordingActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}

extension RecordingActivityAttributes.ContentState {
    @MainActor
    init(recorder: RecorderService, markerCount: Int) {
        let phase: Phase
        switch recorder.state {
        case .paused: phase = recorder.isInterrupted ? .interrupted : .paused
        default: phase = .recording
        }
        self.init(phase: phase, elapsed: recorder.currentTime, asOf: Date(),
                  markerCount: markerCount)
    }
}
