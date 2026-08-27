import Foundation
import AVFoundation
import Testing
import LonghandKit
@testable import LonghandEngines

/// The ingest boundary (§5.4): everything downstream assumes 16 kHz mono PCM,
/// and the quiet-take boost rewrites samples. None of it had a test, so a
/// change to the conversion or the boost could corrupt audio silently.
@Suite struct AudioNormalizerTests {

    private func makeWAV(at url: URL, sampleRate: Double, channels: AVAudioChannelCount,
                         seconds: Double, amplitude: Float) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                                channels: channels))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let samples = try #require(buffer.floatChannelData)[channel]
            for frame in 0..<Int(frames) {
                // A 440 Hz tone: real signal, so resampling has something to do.
                samples[frame] = amplitude * sinf(2 * .pi * 440 * Float(frame) / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
    }

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("longhand-normalizer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func resamplesStereo44kToTheMono16kContract() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("in.wav")
        let destination = directory.appendingPathComponent("out.wav")
        try makeWAV(at: source, sampleRate: 44_100, channels: 2, seconds: 1.0, amplitude: 0.5)

        let (asset, stats) = try AudioNormalizer.normalize(sourceURL: source, destinationURL: destination)

        #expect(asset.sampleRate == AudioNormalizer.targetSampleRate)
        #expect(asset.channelCount == 1)
        #expect(abs(asset.duration - 1.0) < 0.05)
        #expect(stats.channelCount == 2, "the source's channel count is recorded for the §5.3 gate")
        // A half-amplitude tone is nowhere near the quiet threshold.
        #expect(stats.appliedGainDb == nil)

        let written = try AVAudioFile(forReading: destination)
        #expect(written.fileFormat.sampleRate == AudioNormalizer.targetSampleRate)
        #expect(written.fileFormat.channelCount == 1)
    }

    @Test func aVeryQuietTakeIsBoostedAndTheGainIsRecorded() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("quiet.wav")
        let destination = directory.appendingPathComponent("out.wav")
        // ≈ -40 dBFS peak: well under QuietBoost's -12 dBFS trigger.
        try makeWAV(at: source, sampleRate: 16_000, channels: 1, seconds: 0.5, amplitude: 0.01)

        let (_, stats) = try AudioNormalizer.normalize(sourceURL: source, destinationURL: destination)
        let gain = try #require(stats.appliedGainDb, "a near-silent take should have been boosted")
        #expect(gain > 0)
        #expect(gain <= QuietBoost.maxBoostDb)

        // The boost has to survive into the file the engines read: the header
        // is only finalized when the writer deallocs, which this pins.
        let written = try AVAudioFile(forReading: destination)
        #expect(written.length > 0, "boosted output must not be an empty or unfinalized file")
        let format = written.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(written.length)))
        try written.read(into: buffer)
        let samples = try #require(buffer.floatChannelData)[0]
        var peak: Float = 0
        for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[frame])) }
        #expect(peak > 0.05, "output peak \(peak) suggests the gain was not applied")
    }

    @Test func aLoudTakeIsLeftAlone() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("loud.wav")
        let destination = directory.appendingPathComponent("out.wav")
        try makeWAV(at: source, sampleRate: 16_000, channels: 1, seconds: 0.5, amplitude: 0.9)

        let (_, stats) = try AudioNormalizer.normalize(sourceURL: source, destinationURL: destination)
        #expect(stats.appliedGainDb == nil, "a loud take must not be touched")
    }

    @Test func anUnreadableFileFailsWithAStageNotAGuess() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("nonsense.wav")
        try Data("this is not audio".utf8).write(to: source)

        #expect(throws: LonghandError.self) {
            try AudioNormalizer.normalize(sourceURL: source,
                                          destinationURL: directory.appendingPathComponent("o.wav"))
        }
    }
}

/// §5.5 ordering: container first, then MPEG frame sync, then the raw-PCM
/// escape hatch, and only behind explicit user confirmation.
@Suite struct FormatAdapterChainTests {

    @Test func rawPCMRequiresConfirmationBeforeItIsAssumed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("longhand-adapters-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Headerless noise that could plausibly be raw PCM.
        let source = directory.appendingPathComponent("mystery.hda")
        var bytes = Data(count: 32_000)
        for i in 0..<bytes.count { bytes[i] = UInt8((i * 7) % 251) }
        try bytes.write(to: source)

        // Without confirmation the chain must refuse, and say it may be raw PCM.
        var sawCandidate = false
        do {
            _ = try FormatAdapterChain.normalize(url: source,
                                                 destinationURL: directory.appendingPathComponent("a.wav"),
                                                 userConfirmedRawPCM: false)
        } catch let error as LonghandError {
            if case .unsupportedMedia(_, rawPCMCandidate: true) = error { sawCandidate = true }
        }
        #expect(sawCandidate, "an unrecognized file must be offered as a raw-PCM candidate, not decoded silently")

        // With confirmation it is decoded as 16 kHz mono.
        let (asset, _, _) = try FormatAdapterChain.normalize(
            url: source,
            destinationURL: directory.appendingPathComponent("b.wav"),
            userConfirmedRawPCM: true)
        #expect(asset.sampleRate == AudioNormalizer.targetSampleRate)
        #expect(asset.channelCount == 1)
    }
}
