import AVFoundation
import Observation

/// In-app microphone recording (meetings and voice notes; calls stay a §2.2
/// non-goal). Produces an ordinary AAC file that enters the pipeline through
/// the same ingestion boundary as any imported recording.
@Observable
final class RecorderService {

    enum State { case idle, recording, paused, finished }

    private(set) var state: State = .idle
    private(set) var lastError: String?
    /// The system, not the user, holds the recording: a call or another app
    /// taking the mic.
    private(set) var isInterrupted = false
    private var recorder: AVAudioRecorder?
    private(set) var fileURL: URL?
    private var interruptionObserver: NSObjectProtocol?
    /// Identifies the current start attempt, so a stop or discard during the
    /// asynchronous hardware open can disown its result.
    private var startToken: UInt64 = 0

    /// Falls back to the last known duration rather than 0, so an interrupted
    /// take does not appear to rewind.
    var currentTime: TimeInterval {
        if let recorder, state == .recording || state == .paused {
            lastKnownDuration = recorder.currentTime
            return recorder.currentTime
        }
        return state == .finished ? finishedDuration : lastKnownDuration
    }
    private var lastKnownDuration: TimeInterval = 0
    private var finishedDuration: TimeInterval = 0

    /// Rolling input levels for the meter, sampled here rather than in the
    /// view. `WaveformMeter` kept them in `@State` and refilled them from
    /// `onChange(of: context.date)` inside a `TimelineView`, which mutates
    /// state during a view update and tied the meter's cadence to how often the
    /// sheet re-rendered: every `@State` change re-ran its body and re-anchored
    /// `TimelineView(.periodic(from: .now …))`.
    private(set) var levelHistory: [Double] = Array(repeating: 0, count: 48)
    /// Updated only on band crossings: a value that changes 12×/s is noise.
    private(set) var levelBand = "Quiet"

    private var levelTask: Task<Void, Never>?
    /// ~12 Hz reads as live; XCUITest quiescence needs ≥0.25 s.
    private var levelTick: Duration {
        UITestSupport.isUITestRun ? .milliseconds(250) : .milliseconds(80)
    }
    /// Per-tick release. Attack is the raw sample, so onsets register instantly
    /// and tails fade over ~3 ticks rather than vanishing.
    private let levelRelease = 0.78

    private func startSamplingLevel() {
        levelTask?.cancel()
        levelTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.recorder != nil else { return }
                let previous = self.levelHistory.last ?? 0
                let level = max(self.currentLevel(), previous * self.levelRelease)
                self.levelHistory.removeFirst()
                self.levelHistory.append(level)
                let band = level < 0.15 ? "Quiet" : level < 0.5 ? "Speaking" : "Loud"
                if band != self.levelBand { self.levelBand = band }
                try? await Task.sleep(for: self.levelTick)
            }
        }
    }

    private func stopSamplingLevel() {
        levelTask?.cancel()
        levelTask = nil
        levelHistory = Array(repeating: 0, count: levelHistory.count)
        levelBand = "Quiet"
    }

    func currentLevel() -> Double {
        guard state == .recording, let recorder else { return 0 }
        recorder.updateMeters()
        // averagePower is a slow RMS that lags speech onsets; peakPower is
        // instantaneous. Weighted toward peak, but not entirely, so room noise
        // alone cannot peg the meter.
        let average = Double(recorder.averagePower(forChannel: 0))  // ≈ -160…0 dBFS
        let peak = Double(recorder.peakPower(forChannel: 0))
        let db = 0.35 * average + 0.65 * peak
        let floor = -50.0
        return max(0, min(1, (db - floor) / -floor))
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Opens the microphone. Async because every step blocks: `setCategory`
    /// and `setActive` are XPC round-trips to mediaserverd, `AVAudioRecorder`
    /// init builds the file and the AAC encoder, and `record()` starts the
    /// hardware. This type is main-actor isolated, and right after a
    /// transcription those round-trips can take seconds rather than milliseconds.
    func start() async {
        guard state == .idle else {
            lastError = "The recorder was busy (" + Self.describe(state) + "). Try again."
            return
        }
        lastError = nil
        #if DEBUG
        // The failure this models is device-only (another audio client holding
        // the input); the simulator always grants the mic.
        if ProcessInfo.processInfo.arguments.contains("--uitest-fail-record") {
            lastError = "The microphone did not start. (simulated)"
            return
        }
        #endif
        // Anything superseding this attempt bumps the token, so a take
        // cancelled mid-open does not come back as a live recorder nobody owns.
        startToken &+= 1
        let token = startToken

        let url = Self.temporaryRecordingURL()
        let outcome = await Self.onAudioQueue { Self.openRecorder(at: url) }

        guard token == startToken else {
            // Superseded: tear down what we just opened rather than adopt it.
            outcome.recorder?.value.stop()
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let boxed = outcome.recorder else {
            lastError = outcome.error
            return
        }
        observeInterruptions()
        recorder = boxed.value
        fileURL = url
        state = .recording
        startSamplingLevel()
    }

    private struct StartOutcome: @unchecked Sendable {
        var recorder: UncheckedBox<AVAudioRecorder>?
        var error: String?
    }

    /// `nonisolated` because nested in a main-actor type it would inherit that
    /// isolation, and the point is to carry a non-Sendable recorder across.
    nonisolated struct UncheckedBox<Value>: @unchecked Sendable {
        let value: Value
    }

    private static func temporaryRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("Recording \(formatter.string(from: Date())).m4a")
    }

    /// The blocking half, off the main actor.
    private nonisolated static func openRecorder(at url: URL) -> StartOutcome {
        do {
            let session = AVAudioSession.sharedInstance()
            // .defaultToSpeaker keeps concurrent playback off the earpiece;
            // .mixWithOthers stops a recording silencing other audio, and lets
            // test automation inject a synthesized voice through the speaker.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)

            try? FileManager.default.removeItem(at: url)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                // Usually another audio client holding the input, so report
                // the session's own view of the world rather than a shrug.
                return StartOutcome(error: "The microphone did not start. Input available: "
                    + (session.isInputAvailable ? "yes" : "no")
                    + ". Other audio playing: "
                    + (session.isOtherAudioPlaying ? "yes" : "no") + ".")
            }
            return StartOutcome(recorder: UncheckedBox(value: recorder))
        } catch {
            return StartOutcome(error: error.localizedDescription)
        }
    }

    /// Returns a finished or failed recorder to a state `start()` accepts,
    /// without `discard()`'s side effect of deleting the take.
    func reset() {
        guard state != .recording else { return }
        startToken &+= 1
        recorder?.stop()
        recorder = nil
        fileURL = nil
        state = .idle
        lastError = nil
        finishedDuration = 0
        lastKnownDuration = 0
        stopSamplingLevel()
        stopObservingInterruptions()
    }

    static func describe(_ state: State) -> String {
        switch state {
        case .idle: "idle"
        case .recording: "already recording"
        case .paused: "paused"
        case .finished: "holding a finished take"
        }
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        // After a system interruption the session has been deactivated; the
        // recorder will not resume until it is active again.
        if isInterrupted {
            try? AVAudioSession.sharedInstance().setActive(true)
            isInterrupted = false
        }
        guard recorder?.record() == true else {
            lastError = "Recording could not be resumed. Save what you have, or start again."
            return
        }
        state = .recording
    }

    // MARK: - Interruptions

    /// A call, Siri, or another app taking the microphone stops the recorder
    /// without telling the UI.
    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            // Read out here, so only value types cross into the block below.
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            // Registered with `queue: .main`, which the compiler cannot infer
            // from the API. Hopping asynchronously would let a stop() slip in.
            MainActor.assumeIsolated {
                switch type {
                case .began:
                    guard self.state == .recording else { return }
                    self.recorder?.pause()
                    self.isInterrupted = true
                    self.state = .paused
                case .ended:
                    // Only when the system says we may: a call still in
                    // progress must not silently start recording.
                    if options.contains(.shouldResume), self.state == .paused, self.isInterrupted {
                        self.resume()
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    private func stopObservingInterruptions() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
        isInterrupted = false
    }

    /// Async for the same reason as `start()`: `stop()` flushes and closes the
    /// encoded file, and deactivating the session is another mediaserverd
    /// round-trip. The state flips to `.finished` first, so the sheet stops
    /// claiming to record when the button is pressed, not when the file lands.
    func stop() async -> URL? {
        guard state == .recording || state == .paused else { return nil }
        startToken &+= 1
        finishedDuration = recorder?.currentTime ?? 0
        let boxed = recorder.map { UncheckedBox(value: $0) }
        recorder = nil
        state = .finished
        stopSamplingLevel()
        stopObservingInterruptions()
        await Self.onAudioQueue {
            boxed?.value.stop()
            Self.deactivateSession()
        }
        return fileURL
    }

    /// Deletes the temp file immediately (§14.1: nothing lingers outside a job
    /// folder). Teardown is fire-and-forget: the caller is dismissing a sheet
    /// and must not wait on mediaserverd.
    func discard() {
        startToken &+= 1
        let boxed = recorder.map { UncheckedBox(value: $0) }
        let url = fileURL
        recorder = nil
        fileURL = nil
        state = .idle
        finishedDuration = 0
        lastKnownDuration = 0
        stopSamplingLevel()
        stopObservingInterruptions()
        // Still on the shared queue, so it is ordered against the next take.
        Self.audioQueue.async {
            boxed?.value.stop()
            if let url { try? FileManager.default.removeItem(at: url) }
            Self.deactivateSession()
        }
    }

    /// One serial queue for every mediaserverd call. They have to stay
    /// ordered, not just off the main thread: cancelling a sheet and opening
    /// another otherwise lets the discard's `setActive(false)` land after the
    /// new take's `setActive(true)`, which records silence rather than failing
    /// visibly. A serial queue is FIFO; actor continuation ordering is not.
    private nonisolated static let audioQueue = DispatchQueue(
        label: "com.shpala.Longhand.recorder-audio", qos: .userInitiated)

    private nonisolated static func onAudioQueue<T: Sendable>(
        _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            audioQueue.async { continuation.resume(returning: work()) }
        }
    }

    private nonisolated static func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
