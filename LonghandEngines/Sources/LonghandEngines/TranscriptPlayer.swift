import Foundation
import Observation
import AVFoundation

/// Playback for the transcript screen, shared by the iOS and Mac shells.
///
/// `currentTime` is published only while audio is actually moving, so a paused
/// transcript costs nothing. §15.2 ⟨R-16⟩ asks for a throttled observer, and a
/// `TimelineView` around the turn list re-evaluates every turn ten times a
/// second whether or not anything is playing.
@Observable
@MainActor
public final class TranscriptPlayer {

    /// Speeds offered in the UI. 1× first so the picker opens on it.
    public static let availableRates: [Double] = [1.0, 1.25, 1.5, 1.75, 2.0, 0.75]
    public static let skipInterval: TimeInterval = 15

    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var isPlaying = false
    /// Shown on the Lock Screen and in Now Playing.
    public private(set) var title: String?

    /// UI tests slow this down: a continuously animating view never reaches
    /// the quiescence XCUITest waits for before every snapshot.
    public var tickInterval: TimeInterval = 0.1

    /// Applied live, and persisted by the shell across launches.
    public var rate: Double = 1.0 {
        didSet {
            player?.rate = Float(rate)
            if !isPlaying { player?.pause() }   // setting rate can start playback
            publishNowPlaying()
        }
    }

    /// Zero only under UI tests on a phone, which play a real recording.
    public var volume: Float = 1 {
        didSet { player?.volume = volume }
    }

    private var player: AVAudioPlayer?
    private var clock: Task<Void, Never>?
    /// Set by the first `play()`. Opening a transcript must not take the Lock
    /// Screen from whatever else is playing; pressing play may.
    private var holdsNowPlaying = false

    public init() {}

    public var isLoaded: Bool { player != nil }

    // MARK: - Loading

    @discardableResult
    public func load(url: URL, title: String? = nil) -> Bool {
        stop()
        self.title = title
        #if os(iOS)
        // Before the player exists: its audio queue takes the category in
        // force when it is built, and one built under the default category is
        // never eligible for the Lock Screen's Now Playing controls. Setting
        // the category without activating the session leaves other apps'
        // audio alone until play is actually pressed.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        #endif
        guard let loaded = try? AVAudioPlayer(contentsOf: url) else { return false }
        loaded.enableRate = true
        loaded.rate = Float(rate)
        loaded.volume = volume
        loaded.prepareToPlay()
        player = loaded
        duration = loaded.duration
        currentTime = 0
        return true
    }

    public func stop() {
        clock?.cancel()
        clock = nil
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        if holdsNowPlaying {
            holdsNowPlaying = false
            NowPlaying.shared.release(self)
        }
    }

    // MARK: - Transport

    public func toggle() {
        isPlaying ? pause() : play()
    }

    public func play() {
        guard let player else { return }
        activateSessionIfNeeded()
        player.rate = Float(rate)
        player.play()
        isPlaying = true
        startClock()
        holdsNowPlaying = true
        publishNowPlaying()
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        stopClock()
        publishTime()
        publishNowPlaying()
    }

    public func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        publishTime()
        publishNowPlaying()
    }

    public func seekAndPlay(to time: TimeInterval) {
        seek(to: time)
        play()
    }

    public func skip(by seconds: TimeInterval) {
        guard let player else { return }
        seek(to: player.currentTime + seconds)
    }

    // MARK: - Clock

    private func startClock() {
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.tickInterval
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    // Reached the end, or a call took the audio.
                    self.isPlaying = false
                    self.publishNowPlaying()
                    return
                }
            }
        }
    }

    private func stopClock() {
        clock?.cancel()
        clock = nil
    }

    private func publishTime() {
        currentTime = player?.currentTime ?? 0
    }

    /// Only on changes, never per tick: the system extrapolates the elapsed
    /// time from the rate it was given.
    private func publishNowPlaying() {
        guard holdsNowPlaying, player != nil else { return }
        NowPlaying.shared.update(from: self)
    }

    private func activateSessionIfNeeded() {
        #if os(iOS)
        // macOS has no audio session; iOS needs one or playback is silent
        // under the ringer switch.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}
