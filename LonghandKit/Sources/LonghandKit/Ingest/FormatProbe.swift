import Foundation

/// Ingestion-boundary format classification (§5.5), applied in order:
/// 1. Recognized container → hand to AVFoundation as-is.
/// 2. Positive MPEG frame-sync + plausible duration → elementary-stream decode.
/// 3. Otherwise → raw-PCM candidate, accepted only on explicit user confirmation.
/// Permissive MPEG parsers will "open" arbitrary bytes, so step 2 requires
/// several consecutive consistent frames before accepting.
public enum FormatProbe {

    public enum Container: String, Sendable {
        case riffWave, mp4, id3mp3, aiff, caf, flac, ogg
    }

    public struct MPEGInfo: Sendable, Equatable {
        public var version: MPEGVersion
        public var layer: MPEGLayer
        public var sampleRate: Int
        public var channelCount: Int
        public var bitrate: Int
        public var estimatedDuration: TimeInterval
    }

    public enum MPEGVersion: String, Sendable { case v1, v2, v2_5 }
    public enum MPEGLayer: Int, Sendable { case i = 1, ii = 2, iii = 3 }

    public enum Classification: Sendable, Equatable {
        /// A container AVFoundation should be given as-is.
        case container(Container)
        /// Headerless MPEG audio elementary stream (the HiDock .hda case).
        case mpegElementaryStream(MPEGInfo)
        /// Nothing recognizable; may be raw PCM, so it requires user confirmation.
        case unknown
        /// Too small / empty to be audio at all.
        case rejected(reason: String)
    }

    /// Number of consecutive valid frames required for a positive frame-sync.
    static let requiredConsecutiveFrames = 6
    /// Search window for the first sync word.
    static let syncSearchWindow = 64 * 1024

    public static func classify(data: Data, fileLength: Int? = nil) -> Classification {
        let length = fileLength ?? data.count
        guard length >= 128 else { return .rejected(reason: "file too small to be audio") }

        if let container = detectContainer(data) { return .container(container) }
        if let info = detectMPEGStream(data, fileLength: length) { return .mpegElementaryStream(info) }
        return .unknown
    }

    // MARK: - Container signatures

    static func detectContainer(_ data: Data) -> Container? {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data.prefix(12))
        func ascii(_ range: Range<Int>) -> String {
            String(bytes: b[range], encoding: .ascii) ?? ""
        }
        if ascii(0..<4) == "RIFF" && ascii(8..<12) == "WAVE" { return .riffWave }
        if ascii(4..<8) == "ftyp" { return .mp4 }
        if ascii(0..<3) == "ID3" { return .id3mp3 }
        if ascii(0..<4) == "FORM" && ascii(8..<12) == "AIFF" { return .aiff }
        if ascii(0..<4) == "caff" { return .caf }
        if ascii(0..<4) == "fLaC" { return .flac }
        if ascii(0..<4) == "OggS" { return .ogg }
        return nil
    }

    // MARK: - MPEG elementary stream

    struct FrameHeader: Equatable {
        var version: MPEGVersion
        var layer: MPEGLayer
        var bitrate: Int        // bits per second
        var sampleRate: Int
        var padding: Int
        var channelCount: Int

        var samplesPerFrame: Int {
            switch layer {
            case .i: return 384
            case .ii: return 1152
            case .iii: return version == .v1 ? 1152 : 576
            }
        }

        var frameLength: Int {
            switch layer {
            case .i:
                return (12 * bitrate / sampleRate + padding) * 4
            case .ii:
                return 144 * bitrate / sampleRate + padding
            case .iii:
                let coefficient = version == .v1 ? 144 : 72
                return coefficient * bitrate / sampleRate + padding
            }
        }
    }

    static func detectMPEGStream(_ data: Data, fileLength: Int) -> MPEGInfo? {
        let bytes = [UInt8](data)
        let searchEnd = min(bytes.count - 4, syncSearchWindow)
        guard searchEnd > 0 else { return nil }

        for offset in 0..<searchEnd {
            guard bytes[offset] == 0xFF, (bytes[offset + 1] & 0xE0) == 0xE0 else { continue }
            guard let first = parseHeader(bytes, at: offset) else { continue }

            // Walk consecutive frames; require consistency in version/layer/rate.
            var cursor = offset
            var frames = 0
            var totalFrameBytes = 0
            while cursor + 4 <= bytes.count, frames < requiredConsecutiveFrames {
                guard let h = parseHeader(bytes, at: cursor),
                      h.version == first.version, h.layer == first.layer,
                      h.sampleRate == first.sampleRate else { break }
                let len = h.frameLength
                guard len > 4 else { break }
                totalFrameBytes += len
                frames += 1
                cursor += len
                if cursor >= bytes.count { break }
            }
            // A short probe buffer that ends cleanly mid-stream still counts,
            // but never on fewer than two consistent frames.
            let hitEndOfData = cursor + 4 > bytes.count
            guard frames >= requiredConsecutiveFrames || (hitEndOfData && frames >= 2) else { continue }

            let avgFrame = Double(totalFrameBytes) / Double(frames)
            let framesInFile = Double(fileLength - offset) / avgFrame
            let duration = framesInFile * Double(first.samplesPerFrame) / Double(first.sampleRate)

            // Plausible-duration requirement (§5.5): 0.5 s to 24 h.
            guard duration >= 0.5, duration <= 86_400 else { return nil }

            return MPEGInfo(version: first.version, layer: first.layer,
                            sampleRate: first.sampleRate, channelCount: first.channelCount,
                            bitrate: first.bitrate, estimatedDuration: duration)
        }
        return nil
    }

    static func parseHeader(_ bytes: [UInt8], at offset: Int) -> FrameHeader? {
        guard offset + 4 <= bytes.count else { return nil }
        let b1 = bytes[offset + 1], b2 = bytes[offset + 2], b3 = bytes[offset + 3]
        guard bytes[offset] == 0xFF, (b1 & 0xE0) == 0xE0 else { return nil }

        let version: MPEGVersion
        switch (b1 >> 3) & 0x3 {
        case 0: version = .v2_5
        case 2: version = .v2
        case 3: version = .v1
        default: return nil
        }
        let layer: MPEGLayer
        switch (b1 >> 1) & 0x3 {
        case 1: layer = .iii
        case 2: layer = .ii
        case 3: layer = .i
        default: return nil
        }
        let bitrateIndex = Int((b2 >> 4) & 0xF)
        let sampleRateIndex = Int((b2 >> 2) & 0x3)
        guard bitrateIndex > 0, bitrateIndex < 15, sampleRateIndex < 3 else { return nil }

        let sampleRates: [MPEGVersion: [Int]] = [
            .v1: [44_100, 48_000, 32_000],
            .v2: [22_050, 24_000, 16_000],
            .v2_5: [11_025, 12_000, 8_000],
        ]
        let kbps: Int? = {
            switch (version, layer) {
            case (.v1, .i):
                return [nil, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448][bitrateIndex]
            case (.v1, .ii):
                return [nil, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384][bitrateIndex]
            case (.v1, .iii):
                return [nil, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320][bitrateIndex]
            case (_, .i):
                return [nil, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256][bitrateIndex]
            case (_, .ii), (_, .iii):
                return [nil, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160][bitrateIndex]
            }
        }()
        guard let kbps else { return nil }
        let sampleRate = sampleRates[version]![sampleRateIndex]
        let padding = Int((b2 >> 1) & 0x1)
        let channelMode = (b3 >> 6) & 0x3
        return FrameHeader(version: version, layer: layer, bitrate: kbps * 1000,
                           sampleRate: sampleRate, padding: padding,
                           channelCount: channelMode == 3 ? 1 : 2)
    }
}
