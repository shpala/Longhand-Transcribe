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
        // Must happen before launch completes (BGTaskScheduler contract).
        BackgroundExecutionCoordinator.shared.registerLaunchHandler()
        // Early: the system can launch this app in the background purely to
        // deliver a watch recording.
        WatchLink.shared.activate()
        // A take cut off by a crash leaves its Lock Screen card behind, with
        // buttons nothing will answer.
        RecordingActivityController.endOrphans()
        Task { @MainActor in
            AppLibrary.startWatchReporting()
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
            SpeakerProfileStore.deleteAll()
        }
        UITestSupport.seedSynthTranscriptIfRequested()
        UITestSupport.parkJobsIfRequested()
        UITestSupport.requestRecordingIfAsked()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Surfaced on iPadOS when Command is held; inert on iPhone.
        .commands { LonghandCommands() }
    }
}
