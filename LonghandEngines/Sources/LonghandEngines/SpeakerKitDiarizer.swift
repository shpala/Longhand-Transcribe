import Foundation
import AVFoundation
import LonghandKit

#if canImport(SpeakerKit)
import SpeakerKit
import ArgmaxCore

/// SpeakerKit / Pyannote Community-1 diarization (§7). Named
/// `CommunityOneDiarizer` because SpeakerKit's own manager class is already
/// called `SpeakerKitDiarizer`. See docs/IMPLEMENTATION.md for the §4.3
/// distribution licence audit.
public nonisolated final class CommunityOneDiarizer: LonghandKit.SpeakerDiarizer {

    public static let engineID = "speakerkit"
    public let modelIdentifier = "speakerkit/pyannote-community-1"

    /// Measured from a real download, not estimated: 11 MB across the three
    /// components.
    public static let approximateBytes: Int64 = 11 * 1_000_000

    /// Through `isDownloaded`, which seeds from the app bundle first.
    ///
    /// Asking `modelsPresent` instead put the §4.2.3(ii) consent gate in front
    /// of every first diarization on a fresh install: the cache is empty until
    /// something seeds it, so the app asked permission to download 11 MB it was
    /// already carrying. Nothing seeds at launch, and this is the first call
    /// that needs the models, so seeding here is the earliest honest answer.
    public var pendingDownloadBytes: Int64? {
        Self.isDownloaded() ? nil : Self.approximateBytes
    }

    /// Where Argmax actually caches, the same root
    /// `WhisperKitEngine.modelFolder(for:)` uses. Application Support looks
    /// like the right answer and is not one.
    public static func modelFolder() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/argmaxinc/speakerkit-coreml")
    }

    /// Verified against a real download. Folder-exists is not enough: an
    /// interrupted fetch leaves the root behind, and calling that present turns
    /// a resumable download into a diarization failure on every run.
    static let requiredComponents = ["speaker_segmenter", "speaker_embedder", "speaker_clusterer"]

    /// The same three components, shipped inside the app: 11 MB is not worth
    /// a consent prompt, a progress stage and a partial-download detector for
    /// a feature that is not optional (without it there are no speakers at
    /// all, only timestamps, §17).
    ///
    /// Seeded into the cache SpeakerKit already reads rather than loaded from
    /// the bundle: the bundle is read-only and the library wants a writable
    /// model root, so a copy on first launch leaves every existing path
    /// working unchanged.
    static func bundledModelsRoot() -> URL? {
        Bundle.module.url(forResource: "SpeakerModels", withExtension: nil)
    }

    /// Cheap to call: after the first launch this is one directory check per
    /// component.
    @discardableResult
    static func seedBundledModels() -> Bool {
        ModelStaging.excludeFromBackup()
        if modelsPresent() { return true }
        guard let source = bundledModelsRoot() else { return false }
        let destination = modelFolder()
        do {
            // A previous partial download would fail the copy below, and is
            // exactly what the shipped models are meant to replace.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            return false
        }
        return modelsPresent()
    }

    /// The tree on disk, and the rule for whether it will load.
    static func asset(root: URL = modelFolder()) -> ModelAsset {
        ModelAsset(name: "SpeakerKit Community-1",
                   root: root,
                   components: requiredComponents)
    }

    static func modelsPresent(in root: URL = modelFolder()) -> Bool {
        ModelAsset.isPresent(in: root, components: requiredComponents)
    }

    public func diarize(_ input: AudioAsset, expectedSpeakers: Int?,
                 progress: @escaping ProgressSink) async throws -> LonghandKit.DiarizationResult {
        let samples = try Self.loadSamples(url: input.url)

        let diarizer = try await Self.loadedDiarizer(progress: progress)
        // §7.3: never keep diarization models resident past the stage.
        defer { Task { await diarizer.unloadModels() } }

        let options = PyannoteDiarizationOptions(numberOfSpeakers: expectedSpeakers)
        let result = try await diarizer.diarize(audioArray: samples, options: options) { p in
            progress(PipelineProgress(stage: .diarizing, fraction: p.fractionCompleted, isDeterminate: true))
        }

        // A segment can carry several speaker IDs (overlapped speech), and one
        // interval per ID is what §8.2 overlap detection consumes.
        var intervals: [SpeakerInterval] = []
        for segment in result.segments {
            for id in segment.speaker.speakerIds {
                intervals.append(SpeakerInterval(speaker: String(format: "SPEAKER_%02d", id),
                                                 start: TimeInterval(segment.startTime),
                                                 end: TimeInterval(segment.endTime)))
            }
        }
        // Centroids feed §9 identification without a second inference runtime.
        var centroids: [String: [Float]] = [:]
        for (id, embedding) in result.speakerCentroidEmbeddings {
            centroids[String(format: "SPEAKER_%02d", id)] = embedding
        }
        return LonghandKit.DiarizationResult(engine: Self.engineID,
                                             modelIdentifier: modelIdentifier,
                                             intervals: intervals,
                                             forcedSpeakerCount: expectedSpeakers,
                                             centroids: centroids.isEmpty ? nil : centroids)
    }

    /// True once the models are usable, which since they ship with the app
    /// means "after the first call", not "after a download".
    public static func isDownloaded() -> Bool {
        modelsPresent() || seedBundledModels()
    }

    /// Bytes on disk, for the Settings storage line.
    public static func downloadedBytes() -> Int64 {
        asset().bytesOnDisk
    }

    /// Fetches and loads, repairing the cache once if what is on disk turns
    /// out not to be loadable. A half-written tree never heals on its own: the
    /// next download sees files and skips, the load fails again, and every
    /// recording from then on loses its speaker labels.
    static func loadedDiarizer(progress: @escaping ProgressSink) async throws -> SpeakerKitDiarizer {
        do {
            return try await fetchAndLoad(progress: progress)
        } catch let error as LonghandError {
            // The download itself failed, most likely offline. Deleting a cache
            // we cannot replace would turn a retry into a regression.
            throw error
        } catch {
            guard FileManager.default.fileExists(atPath: modelFolder().path) else { throw error }
            asset().purge()
            return try await fetchAndLoad(progress: progress)
        }
    }

    private static func fetchAndLoad(progress: @escaping ProgressSink) async throws -> SpeakerKitDiarizer {
        // The shipped copy first, so `downloadModels` below is only reachable
        // if seeding failed.
        seedBundledModels()
        let diarizer = SpeakerKitDiarizer.pyannote()
        do {
            // Reported as a download, not as mysterious diarization time. The
            // base ModelManager overload is named explicitly: the subclass adds
            // an ambiguous re-declaration that only forwards to it.
            try await (diarizer as ModelManager).downloadModels { p in
                progress(PipelineProgress(stage: .downloadingModel, fraction: p.fractionCompleted,
                                          isDeterminate: true))
            }
        } catch {
            throw LonghandError.modelAssetMissing(
                asset: "SpeakerKit Community-1 models (download failed: \(error.localizedDescription))")
        }
        try await diarizer.loadModels()
        return diarizer
    }

    /// Reads the normalized 16 kHz mono WAV (§5.4) into the float array
    /// SpeakerKit expects. Whole-file in memory, ~230 MB/hour of Float32:
    /// revisit against the §3 memory rule before multi-hour recordings.
    public static func loadSamples(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw LonghandError.decodeFailed(reason: "normalized audio unreadable: \(error.localizedDescription)")
        }
        let format = file.processingFormat
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        let chunk: AVAudioFrameCount = 1 << 18
        while file.framePosition < file.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                throw LonghandError.decodeFailed(reason: "buffer allocation failed")
            }
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return samples
    }
}

#else

/// Placeholder when the SpeakerKit package is absent; the job runner turns the
/// thrown error into the §17 degradation, a transcript with no speaker labels.
public nonisolated final class CommunityOneDiarizer: SpeakerDiarizer {
    public static let engineID = "speakerkit"
    public let modelIdentifier = "speakerkit/pyannote-community-1"

    public func diarize(_ input: AudioAsset, expectedSpeakers: Int?,
                 progress: @escaping ProgressSink) async throws -> DiarizationResult {
        throw LonghandError.engineUnavailable(engine: Self.engineID, language: "n/a")
    }
}
#endif
