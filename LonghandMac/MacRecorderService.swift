import AVFoundation
import Observation

/// AVAudioRecorder without the AVAudioSession choreography iOS needs: macOS
/// has no audio session. AAC m4a into the temp dir, like every capture source.
@Observable
nonisolated final class MacRecorderService {

    enum State { case idle, recording, paused, finished }

    private(set) var state: State = .idle
    private(set) var lastError: String?
    private var recorder: AVAudioRecorder?
    private(set) var fileURL: URL?

    var currentTime: TimeInterval { recorder?.currentTime ?? finishedDuration }
    private var finishedDuration: TimeInterval = 0

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
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() {
        guard state == .idle else { return }
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("mac-take-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                lastError = "Couldn't start recording. Check microphone access in System Settings."
                return
            }
            self.recorder = recorder
            fileURL = url
            state = .recording
        } catch {
            lastError = error.localizedDescription
        }
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        recorder?.record()
        state = .recording
    }

    func stop() -> URL? {
        guard state == .recording || state == .paused, let recorder else { return nil }
        finishedDuration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        state = .finished
        return fileURL
    }

    /// Back to a startable state after a failed start. Refuses while capture is
    /// live, where it would lose the take.
    func reset() {
        guard state != .recording else { return }
        recorder?.stop()
        recorder = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        state = .idle
        lastError = nil
        finishedDuration = 0
    }

    func discard() {
        recorder?.stop()
        recorder = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        state = .idle
    }
}
