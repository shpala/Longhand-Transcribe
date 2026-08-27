import Foundation
import MediaPlayer
import Testing
@testable import LonghandEngines

/// What the Lock Screen and Now Playing are told about a recording.
@MainActor
struct NowPlayingTests {

    @Test func aPlayingRecordingCarriesItsTitleTimeAndRate() {
        let info = NowPlaying.info(title: "Design review", duration: 312, elapsed: 40,
                                   rate: 1.5, isPlaying: true)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Design review")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Longhand")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval == 312)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval == 40)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5)
    }

    /// A rate left at 1.5 while paused makes the system's clock run on, so the
    /// Lock Screen would show time passing in a recording that has stopped.
    @Test func aPausedRecordingReportsRateZeroButKeepsItsSpeed() {
        let info = NowPlaying.info(title: nil, duration: 60, elapsed: 12, rate: 1.5, isPlaying: false)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1.5)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Recording")
    }
}
