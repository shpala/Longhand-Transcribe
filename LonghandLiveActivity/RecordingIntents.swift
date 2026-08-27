import AppIntents
import Foundation
import Observation

// Compiled into the iOS app, its widget extension and the Mac app: the
// Control Center control names Start Recording, and both apps run it. Nothing
// here may import an iOS-only framework.

/// What Siri, a shortcut, the Action Button or a control asked the app to do,
/// held until the library is on screen to act on it. A cold launch runs the
/// intent before any view exists, so a handler installed by a view would miss
/// it; a request left here is picked up when the library appears.
@MainActor
@Observable
final class AppRequests {
    static let shared = AppRequests()

    var startRecording = false
    var openRecording: UUID?
}

/// What a Live Activity button, Siri or a shortcut asks the recorder to do.
enum LiveRecordingCommand: String {
    case pause, resume, mark, stop
}

/// The recorder, as far as anything outside the record sheet can reach it. The
/// sheet installs a handler while a take is open and removes it when it goes;
/// in the widget extension it is never set, and nothing there runs it.
enum LiveRecordingControls {
    @MainActor static var handler: ((LiveRecordingCommand) async -> Void)?

    @MainActor static func send(_ command: LiveRecordingCommand) async {
        await handler?(command)
    }
}

/// Opens Longhand straight into a new recording. Foreground only: the record
/// sheet owns the microphone, and iOS will not let an app start capturing
/// audio from the background on a shortcut's say-so.
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Opens Longhand and starts recording.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRequests.shared.startRecording = true
        return .result()
    }
}
