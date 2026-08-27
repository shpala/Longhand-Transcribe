import Foundation
import Observation
import WatchConnectivity

/// Watch→phone hand-off. A finished take goes over WCSession's queued file
/// transfer (encrypted, local, survives the phone being out of reach) and
/// the phone imports it through the normal pipeline. The phone reports the
/// latest job's state back via application context for the status line.
@Observable
nonisolated final class WatchTransfer: NSObject, WCSessionDelegate, @unchecked Sendable {

    static let shared = WatchTransfer()

    /// Whatever the phone last reported, plus local transfer progress before
    /// the phone has the take at all.
    private(set) var statusLine: String?
    private(set) var pendingTransfers = 0
    /// 0…1 while the phone is transcribing this watch's take.
    private(set) var phoneProgress: Double?
    /// 0…1 while the take is still going up to the phone.
    private(set) var sendProgress: Double?
    /// Stamped on the last take sent from here, so a status push can be
    /// recognised as being about this recording rather than whatever the phone
    /// worked on last.
    private var lastTakeID: String?
    /// The only moment "continue on iPhone" means anything.
    private(set) var hasDeliveredTake = false
    /// The status line is a failure the user can act on, so the view renders
    /// it bright rather than the usual informational grey.
    private(set) var statusIsAlert = false
    /// The take whose upload most recently failed. WCSession only deletes its
    /// copy on delivery, so the file survives and Retry is another
    /// `transferFile` of the same recording.
    private(set) var failedTake: FailedTake?

    struct FailedTake {
        let url: URL
        let markers: [TimeInterval]
        let location: WatchLocationCapture.Fix?
    }

    /// What was sent, keyed by file URL, so a failure can be retried with
    /// the same markers and location rather than a stripped-down re-send.
    private var sendsByURL: [URL: (markers: [TimeInterval], location: WatchLocationCapture.Fix?)] = [:]
    /// Cancelled by us, so the didFinish callback (which arrives with an
    /// error) is not mistaken for a failure worth retrying.
    private var cancelledURLs: Set<URL> = []

    /// Declared in both apps' Info.plists; Handoff will not fire otherwise.
    static let handoffActivityType = "com.shpala.Longhand.library"

    /// Mirrors the phone's "Save location with recordings" setting, pushed in
    /// the status context. One switch for both devices: capturing on the wrist
    /// while the phone has it off would be a privacy surprise.
    private(set) var captureLocationEnabled = false

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        readContext(session.receivedApplicationContext)
    }

    /// Queues the take; WatchConnectivity deletes our copy once delivered.
    func send(_ url: URL, markers: [TimeInterval] = [], location: WatchLocationCapture.Fix? = nil) {
        guard WCSession.isSupported() else {
            statusLine = "iPhone link unavailable"
            return
        }
        let takeID = UUID().uuidString
        lastTakeID = takeID
        phoneProgress = nil
        var metadata: [String: Any] = [
            "recordedAt": Date().timeIntervalSince1970,
            "takeID": takeID,
        ]
        if !markers.isEmpty { metadata["markers"] = markers }
        if let location {
            // A transfer can arrive hours later from somewhere else, so the fix
            // travels with the take it describes.
            metadata["latitude"] = location.latitude
            metadata["longitude"] = location.longitude
            if let accuracy = location.accuracy { metadata["locationAccuracy"] = accuracy }
        }
        // The delivered flag drives the Handoff advertisement, and leaving it
        // set would keep offering to continue a superseded recording.
        hasDeliveredTake = false
        failedTake = nil
        statusIsAlert = false
        sendProgress = 0
        sendsByURL[url] = (markers, location)
        let handle = WCSession.default.transferFile(url, metadata: metadata)
        observe(handle)
        // Whether WCSession has published this transfer into
        // `outstandingFileTransfers` yet is unspecified, so count it explicitly
        // rather than looking it up (as in `didFinish`).
        pendingTransfers = WCSession.default.outstandingFileTransfers
            .filter { $0 !== handle }.count + 1
        statusLine = pendingTransfers > 1
            ? "Sending to iPhone… (\(pendingTransfers) waiting)"
            : "Sending to iPhone…"
    }

    /// A fresh `transferFile` of the same take, markers and location included.
    func retryFailedTake() {
        guard let failedTake else { return }
        self.failedTake = nil
        send(failedTake.url, markers: failedTake.markers, location: failedTake.location)
    }

    /// Withdraws everything still queued, deleting each take's file with it,
    /// so a send stuck behind an out-of-range phone is not a life sentence.
    /// didFinish fires for each cancel with an error, which `cancelledURLs`
    /// teaches it to ignore.
    func cancelPendingTransfers() {
        guard WCSession.isSupported() else { return }
        let outstanding = WCSession.default.outstandingFileTransfers
        guard !outstanding.isEmpty else { return }
        for transfer in outstanding {
            cancelledURLs.insert(transfer.file.fileURL)
            transfer.cancel()
            sendsByURL.removeValue(forKey: transfer.file.fileURL)
            try? FileManager.default.removeItem(at: transfer.file.fileURL)
        }
        pendingTransfers = 0
        sendProgress = nil
        // Every queued take goes, not just the newest, so say how many.
        statusLine = outstanding.count == 1
            ? "Send cancelled, the recording was deleted"
            : "Send cancelled, \(outstanding.count) recordings were deleted"
        statusIsAlert = false
    }

    /// The vended Foundation `Progress` is polled rather than observed, which
    /// is how `AppleSpeechEngine` reads its own, and keeps the transfer (not
    /// Sendable) from crossing an isolation boundary. Only the Double does.
    private func observe(_ handle: WCSessionFileTransfer) {
        let boxed = UncheckedBox(handle)
        Task { @MainActor in
            while boxed.value.isTransferring {
                let fraction = boxed.value.progress.fractionCompleted
                self.sendProgress = fraction
                try? await Task.sleep(for: .milliseconds(400))
            }
            self.sendProgress = nil
        }
    }

    /// Carries a non-Sendable WatchConnectivity object into the one task that
    /// reads it.
    private struct UncheckedBox<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private func readContext(_ context: [String: Any]) {
        guard let title = context["lastTakeTitle"] as? String,
              let state = context["lastTakeState"] as? String else { return }
        let takeID = context["takeID"] as? String
        if let enabled = context["captureLocation"] as? Bool {
            Task { @MainActor in self.captureLocationEnabled = enabled }
        }
        let stage = context["stage"] as? String
        let fraction = context["fraction"] as? Double

        Task { @MainActor in
            let isMine = takeID != nil && takeID == self.lastTakeID
            if isMine {
                // Report the take this watch sent, in the phone's own words.
                if state == "PROCESSING", let stage {
                    self.statusLine = "Your take: \(stage.lowercased())"
                    self.phoneProgress = fraction
                    self.statusIsAlert = false
                } else {
                    self.statusLine = "Your take: \(Self.describe(state))"
                    self.phoneProgress = nil
                    self.statusIsAlert = state == "FAILED"
                }
            } else if self.lastTakeID == nil {
                // Nothing of our own outstanding, so the phone's newest job is
                // useful context.
                self.statusLine = "\(title): \(Self.describe(state))"
                self.phoneProgress = nil
                self.statusIsAlert = state == "FAILED"
            } else {
                // Waiting on a specific take, and this is not it: saying
                // "transcribed ✓" would credit someone else's job to it.
                self.phoneProgress = nil
            }
        }
    }

    private static func describe(_ state: String) -> String {
        switch state {
        case "COMPLETE": "transcribed ✓"
        // Every unhappy line names where to go next.
        case "FAILED": "failed on iPhone. Open Longhand there for details"
        case "INTERRUPTED": "paused. Open Longhand on iPhone to resume"
        default: "processing on iPhone…"
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        // The transfer queue outlives the app process: a take queued behind an
        // out-of-range phone in an earlier launch is still outstanding here.
        let queued = session.outstandingFileTransfers.count
        Task { @MainActor in self.pendingTransfers = queued }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        readContext(applicationContext)
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        // Synchronously, with this transfer excluded: WCSession does not
        // promise to have dropped a finishing transfer from
        // `outstandingFileTransfers` by the time the delegate runs. One
        // reading of 1-instead-of-0 is permanent, since `didFinish` is the only
        // place the count is corrected.
        let remaining = session.outstandingFileTransfers.filter { $0 !== fileTransfer }.count
        Task { @MainActor in
            self.pendingTransfers = remaining
            self.sendProgress = nil
            // A transfer cancelled in cancelPendingTransfers() also lands here
            // wearing an error, with its temp file already gone.
            if self.cancelledURLs.contains(url) {
                self.cancelledURLs.remove(url)
                return
            }
            if let error {
                // The file survives a failed transfer, so keep what was sent:
                // Retry re-issues this exact take.
                let send = self.sendsByURL.removeValue(forKey: url)
                self.failedTake = FailedTake(url: url, markers: send?.markers ?? [],
                                             location: send?.location ?? nil)
                self.statusIsAlert = true
                self.statusLine = "Transfer failed (\(error.localizedDescription)). Tap Retry"
            } else if self.pendingTransfers > 0 {
                self.sendsByURL.removeValue(forKey: url)
                self.hasDeliveredTake = true
                self.statusIsAlert = false
                self.statusLine = "Delivered ✓ · \(self.pendingTransfers) still sending"
            } else {
                self.sendsByURL.removeValue(forKey: url)
                self.hasDeliveredTake = true
                self.statusIsAlert = false
                self.statusLine = "Delivered to iPhone ✓"
            }
        }
    }
}
