import Foundation
import Testing
@testable import LonghandKit

/// Builds a synthetic MPEG-2 Layer II mono 16 kHz 64 kbps stream: the HiDock
/// .hda headerless case (§5.5). Frame length = 144 * 64000 / 16000 = 576 bytes.
private func syntheticHDAFrames(count: Int) -> Data {
    var data = Data()
    for _ in 0..<count {
        var frame = [UInt8](repeating: 0xAB, count: 576)
        frame[0] = 0xFF
        frame[1] = 0xF5   // sync + MPEG2 + Layer II + no CRC
        frame[2] = 0x88   // bitrate index 8 (64 kbps), sample rate index 2 (16 kHz)
        frame[3] = 0xC0   // mono
        data.append(contentsOf: frame)
    }
    return data
}

@Suite struct FormatProbeTests {

    @Test func detectsRIFFWaveContainer() {
        var data = Data("RIFF".utf8)
        data.append(contentsOf: [0x24, 0x00, 0x00, 0x00])
        data.append(Data("WAVEfmt ".utf8))
        data.append(Data(repeating: 0, count: 200))
        #expect(FormatProbe.classify(data: data) == .container(.riffWave))
    }

    @Test func detectsMP4Container() {
        var data = Data(count: 4)
        data.append(Data("ftypM4A ".utf8))
        data.append(Data(repeating: 0, count: 200))
        #expect(FormatProbe.classify(data: data) == .container(.mp4))
    }

    @Test func detectsHeaderlessHDAStream() {
        // 3 minutes' worth of frames by file length; probe sees the first chunk.
        let probe = syntheticHDAFrames(count: 12)
        let fullLength = 576 * 2500   // 2500 frames ≈ 180 s at 72 ms/frame
        let result = FormatProbe.classify(data: probe, fileLength: fullLength)
        guard case let .mpegElementaryStream(info) = result else {
            Issue.record("expected mpegElementaryStream, got \(result)")
            return
        }
        #expect(info.version == .v2)
        #expect(info.layer == .ii)
        #expect(info.sampleRate == 16_000)
        #expect(info.channelCount == 1)
        #expect(info.bitrate == 64_000)
        #expect(abs(info.estimatedDuration - 180.0) < 2.0)
    }

    @Test func riffVariantOfHDAIsClassifiedAsContainerFirst() {
        // §18.1: the .hda RIFF/WAV variant must not be misclassified by the
        // MPEG scan; probe order is container first.
        var data = Data("RIFF".utf8)
        data.append(contentsOf: [0x24, 0x00, 0x00, 0x00])
        data.append(Data("WAVE".utf8))
        data.append(syntheticHDAFrames(count: 4))   // MPEG-looking bytes inside
        #expect(FormatProbe.classify(data: data) == .container(.riffWave))
    }

    @Test func rejectsGarbageAsUnknownNotMPEG() {
        // Permissive MPEG parsers "open" arbitrary bytes; ours must not.
        var generator = SplitMix64(seed: 42)
        var data = Data()
        for _ in 0..<20_000 { data.append(UInt8(truncatingIfNeeded: generator.next())) }
        // Kill accidental sync words so the test is deterministic about intent:
        // random data may contain 0xFF E* pairs, but consecutive consistent
        // frames are what the probe requires.
        let result = FormatProbe.classify(data: data)
        #expect(result == .unknown)
    }

    @Test func rejectsTooSmallFile() {
        let result = FormatProbe.classify(data: Data(repeating: 0xFF, count: 16))
        guard case .rejected = result else {
            Issue.record("expected rejected, got \(result)")
            return
        }
    }

    @Test func implausibleDurationIsNotAccepted() {
        // Valid frames but a file length implying < 0.5 s → not a stream match.
        let probe = syntheticHDAFrames(count: 12)
        let result = FormatProbe.classify(data: probe, fileLength: 576 * 4)
        #expect(result == .unknown)
    }

    @Test func inconsistentFramesAreNotAccepted() {
        var data = syntheticHDAFrames(count: 2)
        // Corrupt the third frame's header where the walker expects sync.
        data.append(Data(repeating: 0x00, count: 576 * 10))
        let result = FormatProbe.classify(data: data, fileLength: 576 * 5000)
        #expect(result == .unknown)
    }
}
