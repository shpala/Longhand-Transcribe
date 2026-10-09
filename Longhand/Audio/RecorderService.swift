import AVFoundation
import CoreMedia
import Observation
import LonghandKit
import LonghandEngines

/// In-app microphone recording (meetings and voice notes; calls stay a §2.2
/// non-goal). Produces an ordinary AAC file that enters the pipeline through
/// the same ingestion boundary as any imported recording.
///
/// The file is written as a fragmented MPEG-4 by `AVAssetWriter`, not by
/// `AVAudioRecorder`: the latter writes the index that makes an `.m4a`
/// readable only when `stop()` runs, so a crash, a memory kill or a dead
/// battery an hour into a meeting left nothing that would open. A fragment
/// lands every few seconds, and every reader the app uses opens a file cut
/// off after one. The take lives in `Documents/Takes`, not `tmp/`, with a
/// sidecar holding what the sheet knew (markers, location), so the next launch
/// can import what a kill left behind.
@Observable
final class RecorderService {

    enum State { case idle, recording, paused, finished }

    private(set) var state: State = .idle
    private(set) var lastError: String?
    /// The system, not the user, holds the recording: a call or another app
    /// taking the mic.
    private(set) var isInterrupted = false
    /// The take stopped itself and cannot go on: the disk filled, the encoder
    /// failed, or the audio system could not be brought back. Nothing is lost:
    /// Stop & Save still saves everything captured before it.
    private(set) var isHalted = false
    private(set) var fileURL: URL?
    /// The microphone in use, by the name the system gives it ("AirPods Pro",
    /// "Built-in Microphone"), so a take through the wrong one is visible
    /// before it is over.
    private(set) var inputName: String?
    private var capture: TakeCapture?
    private var observers: [NSObjectProtocol] = []
    /// Identifies the current start attempt, so a stop or discard during the
    /// asynchronous hardware open can disown its result.
    private var startToken: UInt64 = 0
    private var sidecar = TakeSidecar(startedAt: Date())

    /// Falls back to the last known duration rather than 0, so an interrupted
    /// take does not appear to rewind.
    var currentTime: TimeInterval {
        if let capture, state == .recording || state == .paused {
            lastKnownDuration = capture.recordedSeconds
            return lastKnownDuration
        }
        return state == .finished ? finishedDuration : lastKnownDuration
    }
    /// Written from a getter; not something a view should re-render over.
    @ObservationIgnored private var lastKnownDuration: TimeInterval = 0
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

    /// A take needs room to start, and is stopped before the volume is full:
    /// a writer that cannot flush its next fragment fails the file instead.
    static let startFloorBytes: Int64 = 200 * 1024 * 1024
    static let haltFloorBytes: Int64 = 50 * 1024 * 1024

    private func startSamplingLevel() {
        levelTask?.cancel()
        levelTask = Task { @MainActor [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self, self.capture != nil else { return }
                let previous = self.levelHistory.last ?? 0
                let level = max(self.currentLevel(), previous * self.levelRelease)
                self.levelHistory.removeFirst()
                self.levelHistory.append(level)
                let band = level < 0.15 ? "Quiet" : level < 0.5 ? "Speaking" : "Loud"
                if band != self.levelBand { self.levelBand = band }
                // Every few seconds, not every tick: a volume check is a stat
                // call, cheap but not free at 12 Hz.
                ticks += 1
                if ticks % 50 == 0, self.state == .recording,
                   let free = Self.availableBytes(), free < Self.haltFloorBytes {
                    self.halt(reason: "This device is almost out of space ("
                              + ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                              + " left). Save what you have.")
                }
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
        guard state == .recording, let capture else { return 0 }
        let (average, peak) = capture.levels()
        // averagePower is a slow RMS that lags speech onsets; peakPower is
        // instantaneous. Weighted toward peak, but not entirely, so room noise
        // alone cannot peg the meter.
        let db = 0.35 * Double(average) + 0.65 * Double(peak)
        let floor = -50.0
        return max(0, min(1, (db - floor) / -floor))
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Opens the microphone. Async because every step blocks: `setCategory`
    /// and `setActive` are XPC round-trips to mediaserverd, the writer builds
    /// the file and the AAC encoder, and the engine starts the hardware. This
    /// type is main-actor isolated, and right after a transcription those
    /// round-trips can take seconds rather than milliseconds.
    func start() async {
        guard state == .idle else {
            lastError = "The recorder was busy (" + Self.describe(state) + "). Try again."
            return
        }
        lastError = nil
        isHalted = false
        #if DEBUG
        // The failure this models is device-only (another audio client holding
        // the input); the simulator always grants the mic.
        if ProcessInfo.processInfo.arguments.contains("--uitest-fail-record") {
            lastError = "The microphone did not start. (simulated)"
            return
        }
        #endif
        if let free = Self.availableBytes(), free < Self.startFloorBytes {
            lastError = "Not enough free space to record: "
                + ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                + " left. Free up space and try again."
            return
        }
        // Anything superseding this attempt bumps the token, so a take
        // cancelled mid-open does not come back as a live recorder nobody owns.
        startToken &+= 1
        let token = startToken

        let url = Self.newTakeURL()
        let outcome = await Self.onAudioQueue { Self.openCapture(at: url) }

        guard token == startToken else {
            // Superseded: tear down what we just opened rather than adopt it.
            if let capture = outcome.capture {
                Self.audioQueue.async {
                    _ = capture.finish()
                    Self.removeTake(at: url)
                }
            }
            return
        }
        guard let capture = outcome.capture else {
            lastError = outcome.error
            return
        }
        capture.onFailure = { [weak self] reason in
            Task { @MainActor in self?.halt(reason: reason) }
        }
        // A transcript playing behind the sheet would be recorded into the
        // take, and a Lock Screen play press mid-take would switch the session
        // out from under the microphone.
        TranscriptPlayer.suspendForRecording()
        observeSession(capture)
        self.capture = capture
        fileURL = url
        Self.activeTakeURL = url
        sidecar = TakeSidecar(startedAt: Date())
        writeSidecar()
        inputName = Self.currentInputName()
        state = .recording
        startSamplingLevel()
    }

    private struct StartOutcome: @unchecked Sendable {
        var capture: TakeCapture?
        var error: String?
    }

    /// The blocking half, off the main actor.
    private nonisolated static func openCapture(at url: URL) -> StartOutcome {
        do {
            let session = AVAudioSession.sharedInstance()
            // .defaultToSpeaker keeps concurrent playback off the earpiece;
            // .mixWithOthers stops a recording silencing other audio, and lets
            // test automation inject a synthesized voice through the speaker.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
            try FileManager.default.createDirectory(at: takesDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            let capture = try TakeCapture(url: url)
            try capture.start()
            return StartOutcome(capture: capture)
        } catch {
            return StartOutcome(error: Self.describeStartFailure(error))
        }
    }

    private nonisolated static func describeStartFailure(_ error: Error) -> String {
        let session = AVAudioSession.sharedInstance()
        // Usually another audio client holding the input, so report the
        // session's own view of the world rather than a shrug.
        return "The microphone did not start (\(error.localizedDescription)). Input available: "
            + (session.isInputAvailable ? "yes" : "no")
            + ". Other audio playing: "
            + (session.isOtherAudioPlaying ? "yes" : "no") + "."
    }

    /// Returns a finished or failed recorder to a state `start()` accepts,
    /// without `discard()`'s side effect of deleting the take.
    func reset() {
        guard state != .recording else { return }
        startToken &+= 1
        if let capture {
            Self.audioQueue.async { _ = capture.finish() }
        }
        capture = nil
        fileURL = nil
        Self.activeTakeURL = nil
        state = .idle
        lastError = nil
        isHalted = false
        finishedDuration = 0
        lastKnownDuration = 0
        stopSamplingLevel()
        stopObservingSession()
        TranscriptPlayer.resumeAfterRecording()
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
        capture?.setPaused(true)
        state = .paused
    }

    /// Async for the same reason as `start()`: after an interruption the
    /// session has to be reactivated and the engine restarted, both
    /// mediaserverd round-trips, and they go through the audio queue so a
    /// `discard()` cannot land between them.
    func resume() async {
        guard state == .paused, !isHalted, let capture else { return }
        let reactivate = isInterrupted
        let token = startToken
        let failure = await Self.onAudioQueue { capture.resume(reactivateSession: reactivate) }
        guard token == startToken, state == .paused else { return }
        if let failure {
            lastError = "Recording could not be resumed (\(failure)). Save what you have, or start again."
            return
        }
        lastError = nil
        isInterrupted = false
        inputName = Self.currentInputName()
        state = .recording
    }

    /// Something ended the take that the user did not: the file keeps what
    /// was captured, the sheet says why, and Stop & Save is the way out.
    private func halt(reason: String) {
        guard state == .recording || state == .paused, !isHalted else { return }
        capture?.setPaused(true)
        isHalted = true
        isInterrupted = false
        lastError = reason
        state = .paused
    }

    // MARK: - Session events

    /// A call, Siri, or another app taking the microphone stops the engine
    /// without telling the UI; a route change can stop it too, with a new
    /// input format; a media services reset leaves it dead.
    private func observeSession(_ capture: TakeCapture) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
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
                    self.capture?.setPaused(true)
                    self.isInterrupted = true
                    self.state = .paused
                case .ended:
                    // Only when the system says we may: a call still in
                    // progress must not silently start recording.
                    if options.contains(.shouldResume), self.state == .paused, self.isInterrupted {
                        Task { await self.resume() }
                    }
                @unknown default:
                    break
                }
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputName = Self.currentInputName() }
        })
        // A route change that alters the input format, or any other reason
        // the engine stopped on its own. The writer is untouched; only the
        // engine needs to be brought back.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, capture.owns(note.object) else { return }
            MainActor.assumeIsolated { self.restartCapture(afterReset: false) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartCapture(afterReset: true) }
        })
    }

    /// Brings the engine back after it stopped on its own. While paused there
    /// is nothing to restart yet; `resume()` does it then.
    private func restartCapture(afterReset: Bool) {
        guard state == .recording, let capture else { return }
        let token = startToken
        Task {
            let failure = await Self.onAudioQueue { capture.restart(afterReset: afterReset) }
            guard token == startToken, state == .recording else { return }
            if let failure {
                halt(reason: "The audio system stopped (\(failure)). Save what you have.")
            } else {
                inputName = Self.currentInputName()
            }
        }
    }

    private func stopObservingSession() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        isInterrupted = false
    }

    private static func currentInputName() -> String? {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
    }

    // MARK: - Stop and discard

    /// Async for the same reason as `start()`: finishing flushes and closes the
    /// encoded file, and deactivating the session is another mediaserverd
    /// round-trip. The state flips to `.finished` first, so the sheet stops
    /// claiming to record when the button is pressed, not when the file lands.
    func stop() async -> URL? {
        guard state == .recording || state == .paused, let capture else { return nil }
        startToken &+= 1
        finishedDuration = capture.recordedSeconds
        self.capture = nil
        state = .finished
        stopSamplingLevel()
        stopObservingSession()
        TranscriptPlayer.resumeAfterRecording()
        let failure = await Self.onAudioQueue {
            let failure = capture.finish()
            Self.deactivateSession()
            return failure
        }
        // A writer that failed mid-take has already said so through `halt`;
        // the file holds everything up to its last fragment either way.
        if let failure, lastError == nil { lastError = failure }
        Self.activeTakeURL = nil
        return fileURL
    }

    /// Deletes the take at once (§14.1: nothing lingers outside a job folder).
    /// Teardown is fire-and-forget: the caller is dismissing a sheet and must
    /// not wait on mediaserverd.
    func discard() {
        startToken &+= 1
        let capture = self.capture
        let url = fileURL
        self.capture = nil
        fileURL = nil
        Self.activeTakeURL = nil
        state = .idle
        isHalted = false
        finishedDuration = 0
        lastKnownDuration = 0
        stopSamplingLevel()
        stopObservingSession()
        TranscriptPlayer.resumeAfterRecording()
        // Still on the shared queue, so it is ordered against the next take.
        Self.audioQueue.async {
            _ = capture?.finish()
            if let url { Self.removeTake(at: url) }
            Self.deactivateSession()
        }
    }

    // MARK: - Sidecar

    /// What the sheet knows and the file does not, kept beside it so a take
    /// recovered after a kill keeps its flags, its notes, its location and
    /// the meeting it was recorded in.
    func updateSidecar(markers: [Transcript.Marker]? = nil, location: CapturedLocation? = nil,
                       calendarEvent: CalendarEventContext? = nil) {
        if let markers { sidecar.markers = markers }
        if let location { sidecar.location = location }
        if let calendarEvent { sidecar.calendarEvent = calendarEvent }
        writeSidecar()
    }

    private func writeSidecar() {
        guard let fileURL else { return }
        try? AtomicFile.writeJSON(sidecar, to: Self.sidecarURL(for: fileURL))
    }

    // MARK: - Files

    /// Takes in progress and takes nobody has imported yet. Under Documents,
    /// which the system never purges, unlike `tmp/`.
    nonisolated static var takesDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Takes", isDirectory: true)
    }

    /// The file the live recorder is writing, so a listing of unsaved takes
    /// never offers it for import or deletion.
    private static var activeTakeURL: URL?

    private static func newTakeURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return takesDirectory.appendingPathComponent("Recording \(formatter.string(from: Date())).m4a")
    }

    nonisolated static func sidecarURL(for take: URL) -> URL {
        take.deletingPathExtension().appendingPathExtension("json")
    }

    nonisolated static func removeTake(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: sidecarURL(for: url))
    }

    nonisolated static func availableBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Everything in the takes folder that no live recorder owns: what a
    /// crash left behind, and what an import refused. Sidecars whose audio
    /// has gone (imported, so deleted) are swept on the way.
    static func unsavedTakes() -> [UnsavedTake] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: takesDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let audio = Set(urls.filter { $0.pathExtension == "m4a" })
        for url in urls where url.pathExtension == "json"
            && !audio.contains(url.deletingPathExtension().appendingPathExtension("m4a")) {
            try? FileManager.default.removeItem(at: url)
        }
        return audio
            .filter { $0 != activeTakeURL }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let sidecar = (try? AtomicFile.readJSON(TakeSidecar.self, from: sidecarURL(for: url),
                                                        stage: "take")) ?? nil
                return UnsavedTake(url: url,
                                   sidecar: sidecar,
                                   bytes: Int64(values?.fileSize ?? 0),
                                   duration: duration(of: url),
                                   startedAt: sidecar?.startedAt ?? values?.contentModificationDate ?? Date())
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Records that an import of this take was tried, so the next launch does
    /// not try again on its own and fail the same way.
    static func noteImportAttempt(for take: UnsavedTake) {
        var sidecar = take.sidecar ?? TakeSidecar(startedAt: take.startedAt)
        sidecar.importAttempts += 1
        try? AtomicFile.writeJSON(sidecar, to: sidecarURL(for: take.url))
    }

    /// Seconds of audio a take holds, read from the file itself: a take cut
    /// off by a kill is shorter than its sidecar's clock would say.
    nonisolated static func duration(of take: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: take), file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    // MARK: - Audio queue

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

/// What rides beside a take on disk: the things the sheet knew that the audio
/// file cannot carry.
struct TakeSidecar: Codable, Sendable {
    var startedAt: Date
    /// Flags and typed notes, on the take's own clock.
    var markers: [Transcript.Marker] = []
    var location: CapturedLocation?
    /// The meeting on the calendar when the take started, for its title.
    var calendarEvent: CalendarEventContext?
    var importAttempts = 0

    init(startedAt: Date, markers: [Transcript.Marker] = [], location: CapturedLocation? = nil,
         calendarEvent: CalendarEventContext? = nil, importAttempts: Int = 0) {
        self.startedAt = startedAt
        self.markers = markers
        self.location = location
        self.calendarEvent = calendarEvent
        self.importAttempts = importAttempts
    }

    private enum CodingKeys: String, CodingKey {
        case startedAt, markers, location, calendarEvent, importAttempts
    }

    /// Sidecars written before notes existed hold markers as bare times. A
    /// take a kill left behind under the previous build must still recover
    /// with its flags.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        if let typed = try? container.decode([Transcript.Marker].self, forKey: .markers) {
            markers = typed
        } else {
            let times = try container.decodeIfPresent([TimeInterval].self, forKey: .markers) ?? []
            markers = times.map { Transcript.Marker(time: $0) }
        }
        location = try container.decodeIfPresent(CapturedLocation.self, forKey: .location)
        calendarEvent = try container.decodeIfPresent(CalendarEventContext.self, forKey: .calendarEvent)
        importAttempts = try container.decodeIfPresent(Int.self, forKey: .importAttempts) ?? 0
    }
}

/// A take on disk that is not yet a recording in the library.
struct UnsavedTake: Identifiable, Sendable {
    let url: URL
    let sidecar: TakeSidecar?
    let bytes: Int64
    /// From the file, so a take cut off by a kill reports what it holds.
    let duration: TimeInterval?
    let startedAt: Date
    var id: URL { url }
}

// MARK: - Capture

/// The microphone-to-file half, off the main actor. An `AVAudioEngine` input
/// tap converts whatever the hardware gives to 48 kHz mono and hands it to an
/// `AVAssetWriter` that encodes AAC into a fragmented `.m4a`. Time is counted
/// in frames written, so a pause is simply absent from the file and markers
/// stay on the transcript's clock.
///
/// The tap runs on the audio thread and touches only what the lock guards;
/// everything else is called from the recorder's serial audio queue.
nonisolated final class TakeCapture: @unchecked Sendable {

    private let url: URL
    private var engine = AVAudioEngine()
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let outputFormat: AVAudioFormat
    private let formatDescription: CMAudioFormatDescription
    private var converter: AVAudioConverter?
    private var tapInstalled = false

    private let lock = NSLock()
    private var frames: Int64 = 0
    private var paused = false
    private var failed = false
    private var average: Float = -160
    private var peak: Float = -160

    /// Called once, from the audio thread, when the writer refuses a buffer.
    var onFailure: (@Sendable (String) -> Void)?

    static let sampleRate = 48_000.0
    /// How much a kill can cost: everything after the last fragment written.
    static let fragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

    init(url: URL) throws {
        self.url = url
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: true) else {
            throw CaptureError.format
        }
        outputFormat = format
        var description = format.streamDescription.pointee
        var created: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &created)
        guard status == noErr, let created else { throw CaptureError.format }
        formatDescription = created

        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        writer.movieFragmentInterval = Self.fragmentInterval
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ], sourceFormatHint: created)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.format }
        writer.add(input)
    }

    enum CaptureError: LocalizedError {
        case format
        case writer(String)
        var errorDescription: String? {
            switch self {
            case .format: "the audio format could not be set up"
            case .writer(let reason): reason
            }
        }
    }

    func start() throws {
        guard writer.startWriting() else {
            throw CaptureError.writer(writer.error?.localizedDescription ?? "the file could not be opened")
        }
        writer.startSession(atSourceTime: .zero)
        try startEngine()
    }

    private func startEngine() throws {
        let node = engine.inputNode
        if tapInstalled { node.removeTap(onBus: 0) }
        // The input node's own format, which a tap must match. Conversion to
        // the file's format happens per buffer, so a route change that brings
        // a different rate or channel count needs nothing but a reinstall.
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.format }
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    /// The engine stopped on its own. After a media services reset the old
    /// one is unusable and a new one takes its place; the writer carries on.
    func restart(afterReset: Bool) -> String? {
        if afterReset {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            tapInstalled = false
            engine = AVAudioEngine()
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        do {
            converter = nil
            try startEngine()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func resume(reactivateSession: Bool) -> String? {
        if reactivateSession {
            do { try AVAudioSession.sharedInstance().setActive(true) } catch { return error.localizedDescription }
        }
        if !engine.isRunning {
            if let failure = restart(afterReset: false) { return failure }
        }
        setPaused(false)
        return nil
    }

    func owns(_ object: Any?) -> Bool {
        (object as? AVAudioEngine) === engine
    }

    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }

    var recordedSeconds: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(frames) / Self.sampleRate
    }

    /// Average and peak power of the last buffer, in dBFS.
    func levels() -> (average: Float, peak: Float) {
        lock.lock()
        defer { lock.unlock() }
        return (average, peak)
    }

    /// Closes the file. Returns a message when the writer had failed, in which
    /// case the file still holds everything up to its last fragment.
    func finish() -> String? {
        if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        engine.stop()
        lock.lock()
        let hadFailed = failed
        failed = true
        lock.unlock()
        guard !hadFailed, writer.status == .writing else {
            return writer.error?.localizedDescription ?? "the file could not be finished"
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed ? nil : writer.error?.localizedDescription
    }

    // MARK: Audio thread

    private func handle(_ buffer: AVAudioPCMBuffer) {
        meter(buffer)
        lock.lock()
        let skip = paused || failed
        let position = frames
        lock.unlock()
        guard !skip, buffer.frameLength > 0 else { return }

        guard let converted = convert(buffer) else { return }
        guard input.isReadyForMoreMediaData else { return }   // a hiccup: drop, never block the audio thread
        guard let sample = Self.sampleBuffer(from: converted, at: position,
                                             description: formatDescription) else { return }
        if input.append(sample) {
            lock.lock()
            frames += Int64(converted.frameLength)
            lock.unlock()
        } else {
            lock.lock()
            let first = !failed
            failed = true
            lock.unlock()
            if first {
                onFailure?("The recording could not be written ("
                           + (writer.error?.localizedDescription ?? "unknown error")
                           + "). Save what you have.")
            }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    private func meter(_ buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sumSquares: Float = 0
        var maxAbs: Float = 0
        if let channel = buffer.floatChannelData?[0] {
            let stride = Int(buffer.stride)
            for i in 0..<count {
                let value = channel[i * stride]
                sumSquares += value * value
                maxAbs = max(maxAbs, abs(value))
            }
        } else if let channel = buffer.int16ChannelData?[0] {
            let stride = Int(buffer.stride)
            for i in 0..<count {
                let value = Float(channel[i * stride]) / Float(Int16.max)
                sumSquares += value * value
                maxAbs = max(maxAbs, abs(value))
            }
        } else {
            return
        }
        let rms = (sumSquares / Float(count)).squareRoot()
        let averageDB = max(-160, 20 * log10(max(rms, 1e-8)))
        let peakDB = max(-160, 20 * log10(max(maxAbs, 1e-8)))
        lock.lock()
        average = averageDB
        peak = peakDB
        lock.unlock()
    }

    private static func sampleBuffer(from buffer: AVAudioPCMBuffer, at position: Int64,
                                     description: CMAudioFormatDescription) -> CMSampleBuffer? {
        let frames = CMItemCount(buffer.frameLength)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: CMTime(value: position, timescale: Int32(sampleRate)),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let created = CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: description, sampleCount: frames, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample)
        guard created == noErr, let sample else { return nil }
        let filled = CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, bufferList: buffer.audioBufferList)
        return filled == noErr ? sample : nil
    }
}
