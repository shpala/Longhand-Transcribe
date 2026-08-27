import AVFoundation
import Observation

/// Watch-side recorder: the phone's `RecorderService` minus the route options
/// watchOS does not have. Produces an AAC .m4a that transfers to the phone and
/// enters the normal import pipeline there. MainActor, because this is
/// UI-facing state and the interruption observer arrives on the main queue.
@Observable
final class WatchRecorderService {

    enum State { case idle, recording, paused, finished }

    private(set) var state: State = .idle
    /// The system took the microphone (a call, Siri), so recording stopped
    /// without the user stopping it.
    private(set) var isInterrupted = false
    private var interruptionObserver: NSObjectProtocol?
    private(set) var lastError: String?
    private var recorder: AVAudioRecorder?
    private(set) var fileURL: URL?
    /// Bumped by anything that supersedes an in-flight `start()`.
    private var startToken: UInt64 = 0

    var currentTime: TimeInterval { recorder?.currentTime ?? finishedDuration }
    private var finishedDuration: TimeInterval = 0

    /// Rolling input levels for the meter, owned here rather than by the view,
    /// which kept them in `@State` and refilled them from
    /// `onChange(of: context.date)` inside a `TimelineView`. That mutates state
    /// during a view update, and made the meter's cadence proportional to how
    /// often the whole screen re-rendered.
    private(set) var levelHistory: [Double] = Array(repeating: 0, count: 20)
    private var levelTask: Task<Void, Never>?
    /// Decay applied to the previous sample, so a quiet moment eases down
    /// rather than snapping to zero.
    private let levelRelease = 0.78

    private func startSamplingLevel() {
        levelTask?.cancel()
        levelTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.recorder != nil else { return }
                let previous = self.levelHistory.last ?? 0
                self.levelHistory.removeFirst()
                self.levelHistory.append(max(self.currentLevel(), previous * self.levelRelease))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopSamplingLevel() {
        levelTask?.cancel()
        levelTask = nil
        levelHistory = Array(repeating: 0, count: levelHistory.count)
    }

    /// Normalized 0…1 input level, peak-weighted like the phone meter.
    func currentLevel() -> Double {
        guard state == .recording, let recorder else { return 0 }
        recorder.updateMeters()
        let average = Double(recorder.averagePower(forChannel: 0))
        let peak = Double(recorder.peakPower(forChannel: 0))
        let db = 0.35 * average + 0.65 * peak
        let floor = -50.0
        return max(0, min(1, (db - floor) / -floor))
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Async for the same reason as `RecorderService.start`: every step is an
    /// XPC round-trip or hardware open, and on a main-actor-isolated type they
    /// would all run on the watch's main thread.
    func start() async {
        // `.finished` is a previous take, not a reason to refuse a new one.
        guard state == .idle || state == .finished else { return }
        lastError = nil
        fileURL = nil
        finishedDuration = 0
        // Anything superseding this attempt bumps the token, so a take stopped
        // mid-open does not come back as a live recorder nobody owns.
        startToken &+= 1
        let token = startToken

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-take-\(UUID().uuidString).m4a")
        let outcome = await Self.onAudioQueue { Self.openRecorder(at: url) }

        guard token == startToken else {
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

    /// The blocking half, off the main actor.
    private nonisolated static func openRecorder(at url: URL) -> StartOutcome {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                return StartOutcome(error: "Couldn't start recording. Input available: "
                    + (session.isInputAvailable ? "yes" : "no") + ".")
            }
            return StartOutcome(recorder: UncheckedBox(value: recorder))
        } catch {
            return StartOutcome(error: error.localizedDescription)
        }
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        if isInterrupted {
            try? AVAudioSession.sharedInstance().setActive(true)
            isInterrupted = false
        }
        guard recorder?.record() == true else {
            lastError = "Recording could not be resumed."
            return
        }
        state = .recording
    }

    /// Async for the same reason as `start()`. The state flips to `.finished`
    /// first, so the wrist stops claiming to record when the button is pressed.
    func stop() async -> URL? {
        guard state == .recording || state == .paused, let recorder else { return nil }
        startToken &+= 1
        finishedDuration = recorder.currentTime
        let boxed = UncheckedBox(value: recorder)
        self.recorder = nil
        state = .finished
        stopSamplingLevel()
        stopObservingInterruptions()
        await Self.onAudioQueue {
            boxed.value.stop()
            Self.deactivateSession()
        }
        return fileURL
    }

    /// Same reasoning as the phone's recorder: an unobserved interruption
    /// leaves the wrist showing a running timer over a dead microphone.
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

    /// Fire-and-forget teardown: the caller is dismissing a take and must not
    /// wait on mediaserverd. Still ordered against the next start.
    func discard() {
        startToken &+= 1
        let boxed = recorder.map { UncheckedBox(value: $0) }
        let url = fileURL
        recorder = nil
        fileURL = nil
        state = .idle
        finishedDuration = 0
        stopSamplingLevel()
        // The only place `isInterrupted` is cleared: discarding a
        // call-interrupted take would otherwise carry the banner onto the next.
        stopObservingInterruptions()
        Self.audioQueue.async {
            boxed?.value.stop()
            if let url { try? FileManager.default.removeItem(at: url) }
            Self.deactivateSession()
        }
    }

    /// One serial queue for every mediaserverd call. Ordering matters as much
    /// as getting off the main thread: a discard's `setActive(false)` landing
    /// after the next take's `setActive(true)` records silence rather than
    /// failing visibly. A serial queue is FIFO; actor continuations are not.
    private nonisolated static let audioQueue = DispatchQueue(
        label: "com.shpala.Longhand.watch-recorder-audio", qos: .userInitiated)

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
