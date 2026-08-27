import Foundation
import LonghandEngines

/// The Mac shell's `JobLibraryModel`. No background wrapper (a Mac app keeps
/// running) and no watch link, so it is the shared model with its defaults.
@MainActor
enum MacLibrary {
    static let model = JobLibraryModel()
    /// One player for the window, so the menu bar can drive playback without
    /// reaching into the transcript view's private state.
    static let player = TranscriptPlayer()
    /// Set by the library view so File-menu commands can act on the app.
    static var commands = MacCommandTargets()
}

/// Actions the menu bar performs, published by whichever view owns them.
@MainActor
@Observable
final class MacCommandTargets {
    var startRecording: (() -> Void)?
    var importFiles: (() -> Void)?
    var renameSelection: (() -> Void)?
    var deleteSelection: (() -> Void)?
    var hasSelection = false
    /// Return only renames when the sidebar is the focused pane; an
    /// unguarded bare-Return shortcut ate Returns meant for text fields.
    var sidebarFocused = false
    /// ⌘↑/⌘↓ walk the library; owned by the library view.
    var selectPrevious: (() -> Void)?
    var selectNext: (() -> Void)?
    /// ⌘G/⇧⌘G and ⌘E; owned by whichever transcript view is showing.
    var findNext: (() -> Void)?
    var findPrevious: (() -> Void)?
    /// Whether there is anything to step to: otherwise ⌘G stays enabled over
    /// an empty query or a transcript that never loaded.
    var hasFindHits = false
    var editCurrentTurn: (() -> Void)?
    var hasCurrentTurn = false
}
