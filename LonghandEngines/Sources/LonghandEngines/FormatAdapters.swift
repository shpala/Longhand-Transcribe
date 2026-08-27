import AVFoundation
import AudioToolbox
import LonghandKit

/// Ingestion-boundary adapter chain (§5.5), applied in order:
/// 1. Recognized container → AVFoundation as-is (covers the .hda RIFF variant).
/// 2. Positive MPEG frame-sync + plausible duration → elementary-stream decode.
/// 3. Raw PCM only on explicit user confirmation.
/// 4. Specific rejection before any neural inference (§17).
public nonisolated enum FormatAdapterChain {

    public static let probeWindowBytes = 128 * 1024

    public static func classify(url: URL) throws -> FormatProbe.Classification {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileLength = (attributes[.size] as? Int64).map(Int.init) ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: probeWindowBytes) ?? Data()
        return FormatProbe.classify(data: header, fileLength: fileLength)
    }

    /// Normalizes `url` into 16 kHz mono WAV at `destinationURL` per the §5.4
    /// contract; nothing downstream knows the source was unusual.
    public static func normalize(url: URL, destinationURL: URL,
                          userConfirmedRawPCM: Bool) throws -> (asset: AudioAsset, stats: AudioNormalizer.ChannelStats, classification: FormatProbe.Classification) {
        let classification = try classify(url: url)
        switch classification {
        case .container:
            let (asset, stats) = try AudioNormalizer.normalize(sourceURL: url, destinationURL: destinationURL)
            return (asset, stats, classification)

        case let .mpegElementaryStream(info):
            let asset = try MPEGElementaryStreamDecoder.decode(url: url, info: info, destinationURL: destinationURL)
            let stats = AudioNormalizer.ChannelStats(channelCount: info.channelCount,
                                                     rmsEnergy: [], interChannelCorrelation: nil)
            return (asset, stats, classification)

        case .unknown:
            guard userConfirmedRawPCM else {
                throw LonghandError.unsupportedMedia(detected: "unrecognized data (no container, no MPEG frame sync)",
                                                     rawPCMCandidate: true)
            }
            let asset = try RawPCMDecoder.decode(url: url, destinationURL: destinationURL)
            let stats = AudioNormalizer.ChannelStats(channelCount: 1, rmsEnergy: [], interChannelCorrelation: nil)
            return (asset, stats, classification)

        case let .rejected(reason):
            throw LonghandError.unsupportedMedia(detected: reason, rawPCMCandidate: false)
        }
    }
}

/// Decodes a headerless MPEG audio elementary stream (the HiDock .hda case)
/// via AudioToolbox with an explicit file-type hint, since AVAsset rejects
/// hint-less headerless streams. The probe has already required positive
/// frame-sync and plausible duration before we get here (§5.5).
public nonisolated enum MPEGElementaryStreamDecoder {

    public static func decode(url: URL, info: FormatProbe.MPEGInfo, destinationURL: URL) throws -> AudioAsset {
        let hints: [AudioFileTypeID]
        switch info.layer {
        case .i: hints = [kAudioFileMP1Type, kAudioFileMP2Type, kAudioFileMP3Type]
        case .ii: hints = [kAudioFileMP2Type, kAudioFileMP3Type, kAudioFileMP1Type]
        case .iii: hints = [kAudioFileMP3Type, kAudioFileMP2Type, kAudioFileMP1Type]
        }

        var lastStatus: OSStatus = noErr
        for hint in hints {
            var fileID: AudioFileID?
            lastStatus = AudioFileOpenURL(url as CFURL, .readPermission, hint, &fileID)
            guard lastStatus == noErr, let fileID else { continue }
            defer { AudioFileClose(fileID) }
            do {
                return try convert(fileID: fileID, destinationURL: destinationURL)
            } catch {
                continue
            }
        }
        throw LonghandError.decodeFailed(reason: "MPEG elementary-stream decode failed (layer \(info.layer.rawValue), OSStatus \(lastStatus))")
    }

    private static func convert(fileID: AudioFileID, destinationURL: URL) throws -> AudioAsset {
        var extRef: ExtAudioFileRef?
        var status = ExtAudioFileWrapAudioFileID(fileID, false, &extRef)
        guard status == noErr, let ext = extRef else {
            throw LonghandError.decodeFailed(reason: "ExtAudioFileWrapAudioFileID failed (\(status))")
        }
        defer { ExtAudioFileDispose(ext) }

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: AudioNormalizer.targetSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        status = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)
        guard status == noErr else {
            throw LonghandError.decodeFailed(reason: "client format not accepted (\(status))")
        }

        guard let targetFormat = AVAudioFormat(streamDescription: &clientFormat) else {
            throw LonghandError.decodeFailed(reason: "target format construction failed")
        }
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioNormalizer.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let writer = try AVAudioFile(forWriting: destinationURL, settings: writerSettings,
                                     commonFormat: .pcmFormatInt16, interleaved: true)

        let chunkFrames: UInt32 = 65_536
        var totalFrames: Int64 = 0
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: chunkFrames) else {
                throw LonghandError.decodeFailed(reason: "buffer allocation failed")
            }
            var frameCount = chunkFrames
            let audioBufferList = buffer.mutableAudioBufferList
            status = ExtAudioFileRead(ext, &frameCount, audioBufferList)
            guard status == noErr else {
                throw LonghandError.decodeFailed(reason: "ExtAudioFileRead failed (\(status))")
            }
            if frameCount == 0 { break }
            buffer.frameLength = frameCount
            try writer.write(from: buffer)
            totalFrames += Int64(frameCount)
        }
        guard totalFrames > 0 else {
            throw LonghandError.decodeFailed(reason: "stream decoded to zero frames")
        }
        return AudioAsset(url: destinationURL, sampleRate: AudioNormalizer.targetSampleRate,
                          channelCount: 1, duration: Double(totalFrames) / AudioNormalizer.targetSampleRate)
    }
}

/// Last-resort raw PCM ingest (§5.5): 16 kHz mono 16-bit little-endian,
/// accepted only after the user explicitly confirmed the format. The data is
/// already in the canonical sample format, so this only adds a WAV header.
public nonisolated enum RawPCMDecoder {

    /// Wraps a headerless PCM file in a WAV header.
    ///
    /// Streamed rather than loaded: an hour of 16 kHz mono s16le is ~115 MB,
    /// and the old path held the source, the copy and the destination in
    /// memory at once, three times that on a phone that is about to load a
    /// 626 MB model.
    public static func decode(url: URL, destinationURL: URL) throws -> AudioAsset {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let sourceSize = Int((attributes[.size] as? Int64) ?? 0)
        guard sourceSize >= 3200 else {   // 0.1 s at 16 kHz s16le
            throw LonghandError.unsupportedMedia(detected: "raw PCM candidate too small", rawPCMCandidate: false)
        }
        let byteCount = sourceSize - (sourceSize % 2)

        var header = Data()
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: "RIFF".utf8)
        append32(UInt32(36 + byteCount))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        append32(16)
        append16(1)                                   // PCM
        append16(1)                                   // mono
        append32(UInt32(AudioNormalizer.targetSampleRate))
        append32(UInt32(AudioNormalizer.targetSampleRate) * 2)
        append16(2)                                   // block align
        append16(16)                                  // bits per sample
        header.append(contentsOf: "data".utf8)
        append32(UInt32(byteCount))

        try? FileManager.default.removeItem(at: destinationURL)
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: header),
              let writer = try? FileHandle(forWritingTo: destinationURL),
              let reader = try? FileHandle(forReadingFrom: url) else {
            throw LonghandError.decodeFailed(reason: "could not write the converted audio")
        }
        defer {
            try? writer.close()
            try? reader.close()
        }
        try writer.seekToEnd()
        var remaining = byteCount
        let chunkSize = 1 << 20
        while remaining > 0 {
            let wanted = Swift.min(chunkSize, remaining)
            guard let chunk = try reader.read(upToCount: wanted), !chunk.isEmpty else { break }
            try writer.write(contentsOf: chunk)
            remaining -= chunk.count
        }

        let duration = Double(byteCount / 2) / AudioNormalizer.targetSampleRate
        return AudioAsset(url: destinationURL, sampleRate: AudioNormalizer.targetSampleRate,
                          channelCount: 1, duration: duration)
    }
}
