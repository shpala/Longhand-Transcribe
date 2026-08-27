import SwiftUI
import LonghandEngines

/// Hardware-keyboard verbs for iPadOS, shown when Command is held.
///
/// A subset of the Mac's menu bar rather than a copy: Rename and Delete are
/// bare-Return and ⌘-Delete there because a focused sidebar row is an
/// unambiguous target, and iPadOS has no equivalent here, so those stay on the
/// swipe and the context menu.
@MainActor
@Observable
final class AppCommandTargets {
    static let shared = AppCommandTargets()

    /// Owned by the library view.
    var startRecording: (() -> Void)?
    var importFiles: (() -> Void)?
    /// Owned by whichever transcript view is on screen; nil when none is.
    var findInTranscript: (() -> Void)?
    var togglePlayback: (() -> Void)?
    var skipBack: (() -> Void)?
    var skipForward: (() -> Void)?
    /// Whether there is audio loaded to act on, so the playback items are not
    /// enabled over a transcript with no recording behind it.
    var hasPlayback = false
}

struct LonghandCommands: Commands {
    private var targets: AppCommandTargets { AppCommandTargets.shared }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Recording") { targets.startRecording?() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(targets.startRecording == nil)
            Button("Import…") { targets.importFiles?() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(targets.importFiles == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Find in Transcript") { targets.findInTranscript?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(targets.findInTranscript == nil)
        }

        CommandMenu("Playback") {
            // Not Space: a menu key equivalent is matched before the focused
            // field sees the key, and this app has both a search field and an
            // edit sheet. The Mac works around that with an event monitor.
            Button("Play / Pause") { targets.togglePlayback?() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!targets.hasPlayback)
            Button("Skip Back 15 Seconds") { targets.skipBack?() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!targets.hasPlayback)
            Button("Skip Forward 15 Seconds") { targets.skipForward?() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!targets.hasPlayback)
        }
    }
}
