import CoreSpotlight
import SwiftUI
import LonghandKit
import LonghandEngines

@main
struct LonghandMacApp: App {
    @NSApplicationDelegateAdaptor(LonghandAppDelegate.self) private var delegate

    var body: some Scene {
        // One library window, not a group: there is one library. Closing it is
        // never a dead end (App Review, guideline 4): Window > Longhand Library
        // and the Dock icon bring it back. File > New is taken by New
        // Recording and Import, which left a closed group no way back.
        Window("Longhand", id: "library") {
            MacLibraryView()
        }
        .defaultSize(width: 980, height: 640)
        .commands { LonghandCommands() }

        Settings {
            MacSettingsView()
        }
    }
}

/// Files opened from outside the app: dropped on the dock icon, chosen with
/// "Open With", or double-clicked once Longhand is a handler for the type.
/// Without this the declared document types would be an advertisement the app
/// could not honour.
final class LonghandAppDelegate: NSObject, NSApplicationDelegate {

    private var spaceMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The File menu lists recent recordings from the library model, which
        // the window fills on appearing; a launch that restores no window
        // would otherwise offer an empty menu.
        MacLibrary.model.refresh()
        #if DEBUG
        // The request Start Recording leaves, made from a shell, since there is
        // no command line way to run an App Intent:
        // `driver.sh mac-request-record`. Exercises everything after the intent
        // itself, a closed library window included.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.shpala.Longhand.debug.requestRecord"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppRequests.shared.recordRequested() }
        }
        #endif
        // Space toggles playback. It used to be a bare-space menu shortcut,
        // but menu key equivalents are matched before the key window sees
        // the event, so it ate spaces typed into the search field and the
        // rename alert. Watching the event stream instead lets us yield to
        // anything that currently holds the focus and wants the key itself.
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.charactersIgnoringModifiers == " ",
                  !event.isARepeat,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  let window = event.window,
                  Self.windowMayTogglePlayback(window),
                  MacLibrary.player.isLoaded
            else { return event }
            MacLibrary.player.toggle()
            return nil
        }
    }

    /// A lone `Window` scene quits the app when it closes, and a transcription
    /// running for minutes behind it would die with it. The app stays; the
    /// Window menu and the Dock icon bring the library back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A Spotlight result: the recording is the item's identifier. Through
    /// `AppRequests`, which reopens the library window if it was closed.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard let id = SpotlightIndex.jobID(from: userActivity) else { return false }
        AppRequests.shared.openRequested(id)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
        spaceMonitor = nil
    }

    /// Space is only ours in the library window, and only when nothing in it
    /// is waiting for the key: a focused button (the default button of a
    /// delete confirmation, a checkbox), a text field, or a field editor all
    /// act on Space themselves. Swallowing it there would leave the user
    /// pressing a dead key while the transcript played behind the dialog.
    private static func windowMayTogglePlayback(_ window: NSWindow) -> Bool {
        guard NSApp.modalWindow == nil,
              !window.isSheet,
              window.attachedSheet == nil,
              !(window is NSPanel),
              // The Settings scene is its own window with its own controls.
              window.identifier?.rawValue != "com_apple_SwiftUI_Settings_window"
        else { return false }
        switch window.firstResponder {
        case is NSTextView, is NSControl: return false
        default: return true
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            let defaults = UserDefaults.standard
            let language = defaults.string(forKey: "defaultImportLanguage") ?? "system"
            let speakers = defaults.integer(forKey: "defaultSpeakerCount")
            for url in urls {
                MacLibrary.model.importRecording(
                    from: url,
                    securityScoped: true,
                    declaredLanguage: language == "system" ? nil : language,
                    expectedSpeakerCount: speakers == 0 ? nil : speakers)
            }
        }
    }
}

/// The menu bar. A Mac app that can only be driven by clicking its toolbar is
/// a Mac app in appearance only. These are the verbs, with the shortcuts
/// people already have in their fingers.
struct LonghandCommands: Commands {

    @Environment(\.openWindow) private var openWindow

    private var targets: MacCommandTargets { MacLibrary.commands }
    private var player: TranscriptPlayer { MacLibrary.player }
    /// Newest first, as the library lists them; ten is what a Mac's Open
    /// Recent shows.
    private var recentJobs: ArraySlice<JobRecord> { MacLibrary.model.jobs.prefix(10) }

    var body: some Commands {
        // Both work with the library window closed: the view's own target is
        // used when it is on screen, and otherwise the request goes the way
        // Siri's does, which reopens the window first.
        CommandGroup(replacing: .newItem) {
            Button("New Recording") {
                if let start = targets.startRecording { start() } else { AppRequests.shared.recordRequested() }
            }
            .keyboardShortcut("r", modifiers: .command)
            Button("Import…") {
                if let importFiles = targets.importFiles {
                    importFiles()
                } else {
                    targets.importRequested = true
                    openWindow(id: "library")
                    NSApp.activate()
                }
            }
            .keyboardShortcut("o", modifiers: .command)
            // The library's newest recordings, as a Mac app lists its recent
            // documents. Through the request Siri's Open Recording leaves, so
            // a closed library window reopens on the chosen one.
            Menu("Open Recent") {
                ForEach(recentJobs, id: \.id) { job in
                    Button(job.title) { AppRequests.shared.openRequested(job.id) }
                }
            }
            .disabled(recentJobs.isEmpty)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Rename Recording…") { targets.renameSelection?() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(targets.selectionCount != 1 || !targets.sidebarFocused)
            Button(targets.selectionCount > 1 ? "Delete \(targets.selectionCount) Recordings…" : "Delete Recording…") {
                targets.deleteSelection?()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!targets.hasSelection)
        }

        CommandGroup(after: .textEditing) {
            Button("Find Next") { targets.findNext?() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(targets.findNext == nil || !targets.hasFindHits)
            Button("Find Previous") { targets.findPrevious?() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(targets.findPrevious == nil || !targets.hasFindHits)
            Button("Edit Current Turn…") { targets.editCurrentTurn?() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!targets.hasCurrentTurn)
            Button("Select Passages") { targets.selectPassages?() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(targets.selectPassages == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Previous Recording") { targets.selectPrevious?() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(targets.selectPrevious == nil)
            Button("Next Recording") { targets.selectNext?() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(targets.selectNext == nil)
        }

        // The way back to a closed library window (App Review, guideline 4).
        // A lone `Window` scene does not list itself in the Window menu.
        CommandGroup(before: .windowList) {
            Button("Longhand Library") { openWindow(id: "library") }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }

        CommandMenu("Playback") {
            // No shortcut on purpose: Space is handled by an event monitor in
            // the app delegate, where a focused text field can still win.
            Button(player.isPlaying ? "Pause" : "Play") { player.toggle() }
                .disabled(!player.isLoaded)
            Button("Skip Back 15 Seconds") { player.skip(by: -TranscriptPlayer.skipInterval) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!player.isLoaded)
            Button("Skip Forward 15 Seconds") { player.skip(by: TranscriptPlayer.skipInterval) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!player.isLoaded)
            Divider()
            Picker("Speed", selection: Binding(get: { player.rate },
                                               set: { rate in
                                                   player.rate = rate
                                                   // Persist, so the choice survives opening
                                                   // the next recording.
                                                   UserDefaults.standard.set(rate, forKey: "playbackRate")
                                               })) {
                ForEach(TranscriptPlayer.availableRates, id: \.self) { rate in
                    Text(rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.2g×", rate))
                        .tag(rate)
                }
            }
            .disabled(!player.isLoaded)
        }
    }
}
