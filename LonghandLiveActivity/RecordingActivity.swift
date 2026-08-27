import ActivityKit
import AppIntents
import Foundation

// Compiled into both the app and the widget extension: ActivityKit matches an
// activity to its views by this type, and the buttons on the Lock Screen name
// these intents. The intents only ever run in the app, which owns the
// microphone.

/// A take in progress, as the Lock Screen and the Dynamic Island show it.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case recording, paused
            /// The system took the microphone (a call, Siri). Not a choice the
            /// user made, and nothing is being captured.
            case interrupted
        }

        var phase: Phase
        /// Recorded time at `asOf`, paused time excluded, matching the
        /// transcript's clock.
        var elapsed: TimeInterval
        var asOf: Date
        var markerCount: Int

        /// Where a running clock counts from. Moves forward by every pause, so
        /// the system's own timer text keeps time with no updates from the app.
        var clockStart: Date { asOf.addingTimeInterval(-elapsed) }
    }

    var title: String
}

// One intent per button rather than one intent with a command parameter: an
// enum parameter set in the widget arrived in the app as nil, and the system
// then tried to ask which command was meant, from a Lock Screen card that
// cannot ask anything. With nothing to encode, nothing can go missing.

struct PauseRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause Recording"
    static let isDiscoverable = false
    @MainActor func perform() async throws -> some IntentResult {
        await LiveRecordingControls.send(.pause)
        return .result()
    }
}

struct ResumeRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Resume Recording"
    static let isDiscoverable = false
    @MainActor func perform() async throws -> some IntentResult {
        await LiveRecordingControls.send(.resume)
        return .result()
    }
}

struct MarkRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark This Moment"
    static let isDiscoverable = false
    @MainActor func perform() async throws -> some IntentResult {
        await LiveRecordingControls.send(.mark)
        return .result()
    }
}

struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop and Save Recording"
    static let isDiscoverable = false
    @MainActor func perform() async throws -> some IntentResult {
        await LiveRecordingControls.send(.stop)
        return .result()
    }
}
