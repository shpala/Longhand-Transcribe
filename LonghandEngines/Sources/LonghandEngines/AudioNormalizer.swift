import AVFoundation
import LonghandKit

/// Decodes any AVFoundation-readable source into the §5.4 canonical working
/// format: 16 kHz mono 16-bit PCM WAV, streamed in bounded chunks rather than
/// loaded whole (§3 memory rule). Also measures per-channel energy and
/// inter-channel correlation at import (§5.3 v1 behavior: record, don't branch).
public nonisolated enum AudioNormalizer {

    public struct ChannelStats: Sendable {
        var channelCount: Int
        var rmsEnergy: [Double]
        var interChannelCorrelation: Double?
        /// Set when the whole take was quiet enough that QuietBoost gain was
        /// applied to the transient PCM (the original is never modified).
        var appliedGainDb: Double?
    }

    public static let targetSampleRate: Double = 16_000
    public static let chunkFrames: AVAudioFrameCount = 65_536

    public static func normalize(sourceURL: URL, destinationURL: URL) throws -> (asset: AudioAsset, stats: ChannelStats) {
        let source: AVAudioFile
        do {
            source = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw LonghandError.decodeFailed(reason: "AVFoundation could not open the file: \(error.localizedDescription)")
        }

        let sourceFormat = source.processingFormat
        let channelCount = Int(sourceFormat.channelCount)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: targetSampleRate,
                                               channels: 1, interleaved: true) else {
            throw LonghandError.decodeFailed(reason: "could not create target format")
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw LonghandError.decodeFailed(reason: "no converter from \(sourceFormat) to 16 kHz mono")
        }

        // The writer is deallocated when this helper returns: AVAudioFile only
        // finalizes the WAV header on dealloc, and reading mid-life yields
        // zero frames.
        let converted = try convert(source: source, sourceFormat: sourceFormat,
                                    converter: converter, targetFormat: targetFormat,
                                    channelCount: channelCount, destinationURL: destinationURL)

        let duration = Double(converted.framesWritten) / targetSampleRate
        var correlation: Double?
        if channelCount == 2, converted.sumSquares[0] > 0, converted.sumSquares[1] > 0 {
            correlation = converted.sumCross / (converted.sumSquares[0] * converted.sumSquares[1]).squareRoot()
        }
        let totalFrames = max(1.0, Double(source.length))

        // §5.4 addition: Whisper returns zero segments on ~-36 dBFS speech, so
        // boost the transient PCM when the loudest sample is far below full
        // scale. Peak-referenced, so it cannot clip.
        let peakDb = converted.peakSample > 0
            ? 20 * log10(Double(converted.peakSample) / 32768.0) : -Double.infinity
        var appliedGainDb: Double?
        if let gainDb = QuietBoost.gainDb(forPeakDb: peakDb) {
            try applyGain(db: gainDb, to: destinationURL, format: targetFormat)
            appliedGainDb = gainDb
        }

        let stats = ChannelStats(channelCount: channelCount,
                                 rmsEnergy: converted.sumSquares.map { ($0 / totalFrames).squareRoot() },
                                 interChannelCorrelation: correlation,
                                 appliedGainDb: appliedGainDb)
        let asset = AudioAsset(url: destinationURL, sampleRate: targetSampleRate,
                               channelCount: 1, duration: duration)
        return (asset, stats)
    }

    private struct ConversionResult {
        var framesWritten: AVAudioFramePosition
        var peakSample: Int16
        var sumSquares: [Double]
        var sumCross: Double
    }

    private static func convert(source: AVAudioFile, sourceFormat: AVAudioFormat,
                                converter: AVAudioConverter, targetFormat: AVAudioFormat,
                                channelCount: Int, destinationURL: URL) throws -> ConversionResult {
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let writer = try AVAudioFile(forWriting: destinationURL, settings: writerSettings,
                                     commonFormat: .pcmFormatInt16, interleaved: true)

        var sumSquares = [Double](repeating: 0, count: channelCount)
        var sumCross = 0.0
        var framesWritten: AVAudioFramePosition = 0
        var reachedEnd = false
        var peakSample: Int16 = 0

        while !reachedEnd {
            // A long import spends real time in this synchronous loop, so a
            // pause would otherwise wait out the whole conversion.
            try Task.checkCancellation()
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else {
                throw LonghandError.decodeFailed(reason: "buffer allocation failed")
            }
            // Reading at exact EOF throws a bare nilError on compressed
            // sources instead of returning an empty buffer, and the position
            // check must come first.
            if source.framePosition >= source.length {
                reachedEnd = true
            } else {
                try source.read(into: inBuffer)
                if inBuffer.frameLength == 0 {
                    reachedEnd = true
                } else {
                    accumulateStats(inBuffer, sumSquares: &sumSquares, sumCross: &sumCross)
                }
            }

            let ratio = targetSampleRate / sourceFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(max(inBuffer.frameLength, 1)) * ratio) + 1024
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
                throw LonghandError.decodeFailed(reason: "buffer allocation failed")
            }

            var fed = false
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                if reachedEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let conversionError {
                throw LonghandError.decodeFailed(reason: conversionError.localizedDescription)
            }
            if outBuffer.frameLength > 0 {
                if let samples = outBuffer.int16ChannelData?[0] {
                    for i in 0..<Int(outBuffer.frameLength) {
                        let magnitude = samples[i] == Int16.min ? Int16.max : abs(samples[i])
                        if magnitude > peakSample { peakSample = magnitude }
                    }
                }
                try writer.write(from: outBuffer)
                framesWritten += AVAudioFramePosition(outBuffer.frameLength)
            }
            if status == .endOfStream { break }
        }

        return ConversionResult(framesWritten: framesWritten, peakSample: peakSample,
                                sumSquares: sumSquares, sumCross: sumCross)
    }

    /// Streams the transient WAV through a gain multiply into a sibling temp
    /// file, then atomically replaces it. Only ever the 16 kHz mono working
    /// copy; the retained original is untouched (§13.4).
    private static func applyGain(db: Double, to url: URL, format: AVAudioFormat) throws {
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent("gain-\(UUID().uuidString).wav")
        // The writer must be deallocated before the swap: AVAudioFile finalizes
        // the WAV header on dealloc, and a file replaced mid-life carries a
        // zero-length data chunk, which reads as silence.
        try writeBoosted(from: url, to: tempURL, gain: QuietBoost.linearGain(forDb: db), format: format)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    private static func writeBoosted(from sourceURL: URL, to tempURL: URL,
                                     gain: Double, format: AVAudioFormat) throws {
        let reader = try AVAudioFile(forReading: sourceURL, commonFormat: .pcmFormatInt16, interleaved: true)
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let writer = try AVAudioFile(forWriting: tempURL, settings: writerSettings,
                                     commonFormat: .pcmFormatInt16, interleaved: true)
        while reader.framePosition < reader.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
                throw LonghandError.decodeFailed(reason: "buffer allocation failed")
            }
            try reader.read(into: buffer)
            guard buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] else { break }
            for i in 0..<Int(buffer.frameLength) {
                let boosted = (Double(samples[i]) * gain).rounded()
                samples[i] = Int16(max(Double(Int16.min), min(Double(Int16.max), boosted)))
            }
            try writer.write(from: buffer)
        }
    }

    private static func accumulateStats(_ buffer: AVAudioPCMBuffer,
                                        sumSquares: inout [Double], sumCross: inout Double) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = min(sumSquares.count, Int(buffer.format.channelCount))
        for c in 0..<channelCount {
            var acc = 0.0
            let samples = channels[c]
            for i in 0..<frames { acc += Double(samples[i]) * Double(samples[i]) }
            sumSquares[c] += acc
        }
        if channelCount == 2 {
            let left = channels[0], right = channels[1]
            var acc = 0.0
            for i in 0..<frames { acc += Double(left[i]) * Double(right[i]) }
            sumCross += acc
        }
    }
}
