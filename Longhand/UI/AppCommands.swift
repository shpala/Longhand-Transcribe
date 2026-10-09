import SwiftUI
import LonghandEngines

/// Hardware-keyboard verbs for iPadOS, shown when Command is held.
///
/// A subset of the Mac's menu bar rather than a copy: Rename and Delete are
/// bare-Return and ⌘-Delete there because a focused sidebar row is an
/// unambiguous target, and iPadOS has no equivalent here, so those stay on the
/// swipe and the context menu.
///
/// The targets are focused scene values, not a shared object: with several
/// windows open, ⌘R has to reach the window the keyboard is in, and a single
/// set of closures would belong to whichever view appeared last and go nil
/// when any of them closed.

/// What the library window answers to.
///
/// Equatable by hand, with the closures left out: a focused value that is
/// never equal to its last value is republished on every render, and inside
/// a pushed navigation destination that republishing renders again, which
/// kept the main thread busy for as long as the transcript was on screen.
struct LibraryActions: Equatable {
    var startRecording: () -> Void
    var importFiles: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

/// What a transcript on screen answers to.
struct TranscriptActions: Equatable {
    var find: () -> Void
    var togglePlayback: () -> Void
    var skipBack: () -> Void
    var skipForward: () -> Void
    /// Whether there is audio loaded to act on, so the playback items are not
    /// enabled over a transcript with no recording behind it.
    var hasPlayback: Bool

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.hasPlayback == rhs.hasPlayback }
}

extension FocusedValues {
    @Entry var libraryActions: LibraryActions?
    @Entry var transcriptActions: TranscriptActions?
}

struct LonghandCommands: Commands {
    @FocusedValue(\.libraryActions) private var library
    @FocusedValue(\.transcriptActions) private var transcript

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Recording") { library?.startRecording() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(library == nil)
            Button("Import…") { library?.importFiles() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(library == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Find in Transcript") { transcript?.find() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(transcript == nil)
        }

        CommandMenu("Playback") {
            // Not Space: a menu key equivalent is matched before the focused
            // field sees the key, and this app has both a search field and an
            // edit sheet. The Mac works around that with an event monitor.
            Button("Play / Pause") { transcript?.togglePlayback() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(transcript?.hasPlayback != true)
            Button("Skip Back 15 Seconds") { transcript?.skipBack() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(transcript?.hasPlayback != true)
            Button("Skip Forward 15 Seconds") { transcript?.skipForward() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(transcript?.hasPlayback != true)
        }
    }
}
