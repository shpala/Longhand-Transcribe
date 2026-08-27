import Foundation
import UIKit
import WatchConnectivity
import LonghandKit
import LonghandEngines

/// iPhone side of the watch hand-off. A take arrives as a WCSession file
/// transfer (the system launches this app in the background to receive it), is
/// imported through the normal pipeline as a third ingest source, and the
/// latest job's state is reported back for the watch's status line.
nonisolated final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {

    static let shared = WatchLink()

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Parked takes that were never imported, counted in the storage figure so
    /// a repeatedly failing import cannot hoard audio invisibly.
    static func incomingBytes() -> Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: incomingDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(into: Int64(0)) {
            $0 += Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Parked takes only exist because an import kept failing, and audio
    /// nobody can reach should not sit in Documents forever (§14.1).
    static func pruneStaleIncoming(olderThan age: TimeInterval = 14 * 24 * 3600) {
        let cutoff = Date().addingTimeInterval(-age)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: incomingDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in urls {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// The settings the watch obeys, with no job to report. Riding along with
    /// a job status push would leave a library with no jobs (or a toggle
    /// switched off and never followed by a recording) acting on a stale
    /// answer. Called when the setting changes and at activation.
    func pushSettings() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        var payload = lastPushedContext
        payload["captureLocation"] = LocationCapture.isEnabled
        send(payload)
    }

    /// Application context replaces wholesale, so merge rather than overwrite:
    /// pushing settings must not erase the last job status, or vice versa.
    private func send(_ payload: [String: Any]) {
        lock.lock()
        lastPushedContext = payload
        lock.unlock()
        try? WCSession.default.updateApplicationContext(payload)
    }

    private var lastPushedContext: [String: Any] = [:]

    /// `takeID` is what the watch stamped on the recording it sent, so the
    /// wrist can tell "your take is transcribing" from "the phone is busy".
    func push(jobID: UUID?, title: String, state: String,
              stage: String? = nil, fraction: Double? = nil) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }

        var payload: [String: Any] = [
            "lastTakeTitle": title,
            "lastTakeState": state,
            // One setting governs both devices: the watch has no Settings
            // screen of its own.
            "captureLocation": LocationCapture.isEnabled,
        ]
        if let jobID, let takeID = Self.takeID(forJob: jobID) {
            payload["takeID"] = takeID
        }
        if let stage { payload["stage"] = stage }
        if let fraction { payload["fraction"] = fraction }
        send(payload)
    }

    /// Progress updates, rate-limited: application context is coalesced by the
    /// system, but there is no reason to hand it ten updates a second.
    func pushProgress(jobID: UUID, title: String, progress: PipelineProgress) {
        let now = Date()
        lock.lock()
        let due = now.timeIntervalSince(lastProgressPush) > 2
        if due { lastProgressPush = now }
        lock.unlock()
        guard due else { return }
        push(jobID: jobID, title: title, state: "PROCESSING",
             stage: JobPipeline.stageDisplayName(progress.stage),
             fraction: progress.isDeterminate ? progress.fraction : nil)
    }

    private let lock = NSLock()
    private var lastProgressPush = Date.distantPast

    /// The take identifier recorded at import, read back from the job folder
    /// so this survives the app being relaunched between transfer and finish.
    private static func takeID(forJob jobID: UUID) -> String? {
        let files = JobStore.files(for: jobID)
        let metadata = (try? AtomicFile.readJSON(ImportMetadata.self, from: files.metadata, stage: "job")) ?? nil
        return metadata?.sourceTakeID
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    // MARK: - Receiving a take

    /// Documents, not `tmp`: the system launches this app in the background
    /// only long enough to hand the file over, and purges `tmp` whenever it
    /// likes, so a take parked there can vanish before the import runs.
    static var incomingDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Incoming", isDirectory: true)
    }

    /// What arrived with the audio, written beside it so the import can be
    /// finished by a later launch if this one is cut short.
    private struct PendingTake: Codable {
        var audioFileName: String
        var takeID: String?
        var markers: [TimeInterval]
        var receivedAt: Date
        /// From the transfer metadata: arrival can be hours later if the phone
        /// was out of range, and naming a take for when it synced is wrong.
        var recordedAt: Date?
        var latitude: Double?
        var longitude: Double?
        var locationAccuracy: Double?

        /// Where the watch was when it recorded, which only the watch can know:
        /// by the time a transfer arrives the phone may be elsewhere.
        var location: CapturedLocation? {
            guard let latitude, let longitude else { return nil }
            return CapturedLocation(latitude: latitude, longitude: longitude,
                                    horizontalAccuracyMeters: locationAccuracy)
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The system deletes file.fileURL when this method returns, so the
        // move has to happen synchronously, here.
        let id = UUID().uuidString
        let directory = Self.incomingDirectory
        let audio = directory.appendingPathComponent("\(id).m4a")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file.fileURL, to: audio)
            let pending = PendingTake(audioFileName: audio.lastPathComponent,
                                      takeID: file.metadata?["takeID"] as? String,
                                      markers: file.metadata?["markers"] as? [TimeInterval] ?? [],
                                      receivedAt: Date(),
                                      recordedAt: (file.metadata?["recordedAt"] as? TimeInterval)
                                          .map(Date.init(timeIntervalSince1970:)),
                                      latitude: file.metadata?["latitude"] as? Double,
                                      longitude: file.metadata?["longitude"] as? Double,
                                      locationAccuracy: file.metadata?["locationAccuracy"] as? Double)
            try AtomicFile.writeJSON(pending, to: directory.appendingPathComponent("\(id).json"))
        } catch {
            // The watch has already said "Delivered ✓" and WCSession deletes
            // its copy when this returns, so a silent return loses the audio.
            Task { @MainActor in
                AppLibrary.model.errorAlert = .init(
                    title: "Couldn't Save Watch Recording",
                    message: "A recording arrived from your watch but could not be written to this iPhone: \(JobLibraryModel.describe(error))")
            }
            return
        }
        Task { @MainActor in await Self.drainIncoming() }
    }

    /// Two deliveries can drain the same folder at once: the import awaits, and
    /// a second drain entering that window would import the same parked take
    /// again, producing duplicate jobs.
    @MainActor private static var isDraining = false

    /// Imports every take waiting in `Incoming`, holding a background assertion
    /// so the app is not suspended mid-import. Called on delivery and again at
    /// launch: if the background window runs out, the take is still on disk.
    @MainActor
    static func drainIncoming() async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        let directory = incomingDirectory
        let manifests = ((try? FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !manifests.isEmpty else { return }

        pruneStaleIncoming()
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "Import watch take")
        defer { if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) } }

        let defaults = UserDefaults.standard
        let language = defaults.string(forKey: "defaultImportLanguage") ?? "system"
        let speakers = defaults.integer(forKey: "defaultSpeakerCount")

        for manifest in manifests {
            guard let pending = (try? AtomicFile.readJSON(PendingTake.self, from: manifest, stage: "watch take")) ?? nil else {
                try? FileManager.default.removeItem(at: manifest)
                continue
            }
            let audio = directory.appendingPathComponent(pending.audioFileName)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                try? FileManager.default.removeItem(at: manifest)
                continue
            }
            do {
                let imported = try await ImportService.importRecording(
                    from: audio,
                    securityScoped: false,
                    declaredLanguage: language == "system" ? nil : language,
                    expectedSpeakerCount: speakers == 0 ? nil : speakers,
                    location: LocationCapture.isEnabled ? pending.location : nil,
                    title: RecordingTitle.forTake(at: pending.recordedAt ?? pending.receivedAt, source: .watch),
                    sourceTakeID: pending.takeID,
                    markers: pending.markers)
                try? FileManager.default.removeItem(at: audio)
                try? FileManager.default.removeItem(at: manifest)
                AppLibrary.model.refresh()
                if imported.record.state != .failed {
                    AppLibrary.model.start(jobID: imported.record.id)
                }
            } catch {
                // Leave it parked; the next launch tries again.
                AppLibrary.model.errorAlert = .init(title: "Couldn't Import Watch Recording",
                                                    message: JobLibraryModel.describe(error))
            }
        }

        // A take that landed while this drain was running would otherwise wait
        // for the next launch, since its own drain returned at the guard.
        let arrivedMeanwhile = ((try? FileManager.default.contentsOfDirectory(at: directory,
                                                                              includingPropertiesForKeys: nil)) ?? [])
            .contains { $0.pathExtension == "json" }
        if arrivedMeanwhile {
            isDraining = false
            await drainIncoming()
        }
    }
}
