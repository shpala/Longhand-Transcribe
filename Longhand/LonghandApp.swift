//
//  LonghandApp.swift
//  Longhand
//
//  Created by Emilia Nadelson on 18/08/2026.
//

import SwiftUI
import LonghandEngines

@main
struct LonghandApp: App {
    init() {
        // Before any view reads the setting it overrides, or restores.
        UITestSupport.applyDefaultLanguageOverride()
        // Must happen before launch completes (BGTaskScheduler contract).
        BackgroundExecutionCoordinator.shared.registerLaunchHandler()
        // Early: the system can launch this app in the background purely to
        // deliver a watch recording.
        WatchLink.shared.activate()
        // A take cut off by a crash leaves its Lock Screen card behind, with
        // buttons nothing will answer.
        RecordingActivityController.endOrphans()
        // Synchronously, not in the task below: the library's first refresh
        // can run before a task scheduled here does, and the widget's
        // snapshot would then wait for the next change.
        AppLibrary.startWatchReporting()
        Task { @MainActor in
            // Anything the watch delivered while this app was asleep, or that
            // ran out of background time mid-import, is finished here.
            await WatchLink.drainIncoming()
            // So a watch paired to an empty library still learns the setting.
            WatchLink.shared.pushSettings()
        }
        // Starts from an empty library, so assertions cannot match state left
        // over from a previous run. Debug only: this deletes everything.
        #if DEBUG
        if CommandLine.arguments.contains("--uitest-reset") {
            try? FileManager.default.removeItem(at: ImportService.recordingsRoot)
            try? FileManager.default.removeItem(at: RecorderService.takesDirectory)
            SpeakerProfileStore.deleteAll()
            // The picker's inline model languages are use-driven, and a
            // previous run's choice is state too.
            UserDefaults.standard.removeObject(forKey: TranscriptionLanguages.recentKey)
        }
        UITestSupport.seedSynthTranscriptIfRequested()
        UITestSupport.parkJobsIfRequested()
        UITestSupport.stageUnsavedTakeIfRequested()
        UITestSupport.requestRecordingIfAsked()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Surfaced on iPadOS when Command is held; inert on iPhone.
        .commands { LonghandCommands() }

        // "Open in New Window" on an iPad library row. The system offers
        // this scene only where several windows are supported, so the iPhone
        // never sees it.
        WindowGroup("Transcript", for: UUID.self) { $jobID in
            TranscriptWindow(jobID: $jobID)
        }
    }
}
