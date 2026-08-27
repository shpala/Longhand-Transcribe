import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Playback controls outside the app: the Lock Screen and Control Center on
/// iOS, Now Playing and the media keys on the Mac.
///
/// One owner at a time. iOS gives each transcript screen its own player, so
/// whichever started playing last holds the controls, and only its own `stop`
/// takes them away again: a screen closing in the background must not clear
/// the card of the one that is playing.
@MainActor
final class NowPlaying {

    static let shared = NowPlaying()

    private weak var owner: TranscriptPlayer?
    private var registered = false

    /// What the system shows. Built separately so the contents can be tested
    /// without a running media session.
    static func info(title: String?, duration: TimeInterval, elapsed: TimeInterval,
                     rate: Double, isPlaying: Bool) -> [String: Any] {
        [
            MPMediaItemPropertyTitle: title ?? "Recording",
            MPMediaItemPropertyArtist: "Longhand",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            // Zero while paused, or the system clock keeps running. `0.0`, not
            // `0`: each branch becomes `Any` on its own, and a bare 0 is an Int
            // the system does not read as a rate.
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
    }

    func update(from player: TranscriptPlayer) {
        if owner !== player {
            owner = player
        }
        registerCommandsOnce()
        var info = Self.info(title: player.title, duration: player.duration,
                             elapsed: player.currentTime, rate: player.rate,
                             isPlaying: player.isPlaying)
        if let artwork = Self.artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        #if os(macOS)
        // The Mac shows Now Playing only for an app that says what state it is in.
        center.playbackState = player.isPlaying ? .playing : .paused
        #endif
    }

    func release(_ player: TranscriptPlayer) {
        guard owner === player else { return }
        owner = nil
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        #if os(macOS)
        center.playbackState = .stopped
        #endif
    }

    // MARK: - Remote commands

    /// Registered once for the process and routed to whoever owns playback,
    /// so a second transcript screen never stacks a second set of handlers.
    private func registerCommandsOnce() {
        guard !registered else { return }
        registered = true
        let commands = MPRemoteCommandCenter.shared()

        commands.playCommand.addTarget { [weak self] _ in
            self?.route { $0.play() } ?? .noActionableNowPlayingItem
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            self?.route { $0.pause() } ?? .noActionableNowPlayingItem
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.route { $0.toggle() } ?? .noActionableNowPlayingItem
        }

        let interval = NSNumber(value: TranscriptPlayer.skipInterval)
        commands.skipForwardCommand.preferredIntervals = [interval]
        commands.skipForwardCommand.addTarget { [weak self] _ in
            self?.route { $0.skip(by: TranscriptPlayer.skipInterval) } ?? .noActionableNowPlayingItem
        }
        commands.skipBackwardCommand.preferredIntervals = [interval]
        commands.skipBackwardCommand.addTarget { [weak self] _ in
            self?.route { $0.skip(by: -TranscriptPlayer.skipInterval) } ?? .noActionableNowPlayingItem
        }

        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            return self?.route { $0.seek(to: position) } ?? .noActionableNowPlayingItem
        }

        commands.changePlaybackRateCommand.supportedPlaybackRates =
            TranscriptPlayer.availableRates.sorted().map { NSNumber(value: $0) }
        commands.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let rate = Double(event.playbackRate)
            return self?.route { $0.rate = rate } ?? .noActionableNowPlayingItem
        }

        // Track skipping means nothing for a single recording.
        commands.nextTrackCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false
    }

    /// Remote commands arrive on the main thread, but the API does not
    /// promise it in a form the compiler can see, so the hop is explicit.
    private nonisolated func route(_ action: @escaping @MainActor (TranscriptPlayer) -> Void)
        -> MPRemoteCommandHandlerStatus {
        Task { @MainActor in
            guard let owner = NowPlaying.shared.owner else { return }
            action(owner)
        }
        return .success
    }

    // MARK: - Artwork

    private static let artwork: MPMediaItemArtwork? = {
        #if canImport(UIKit)
        guard let image = UIImage(named: "BrandMark") else { return nil }
        #elseif canImport(AppKit)
        guard let image = NSImage(named: "BrandMark") else { return nil }
        #endif
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }()
}
