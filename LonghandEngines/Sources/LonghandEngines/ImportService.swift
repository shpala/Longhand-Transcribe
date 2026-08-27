import Foundation
import CryptoKit
import AVFoundation
import LonghandKit

/// Copies a picked recording into the app container and creates the job (§5.1,
/// §5.2). Processing never mutates the original. Disk preconditions are checked
/// before the copy, not at the last checkpoint write (§13.3).
public nonisolated enum ImportService {

    /// The ISO 6709 metadata iOS embeds in Voice Memos and camera files. A
    /// local parse of our own copy.
    public static func embeddedLocation(of url: URL) async -> CapturedLocation? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items where item.identifier == .commonIdentifierLocation {
            if let string = try? await item.load(.stringValue),
               let location = CapturedLocation.parseISO6709(string) {
                return location
            }
        }
        return nil
    }

    public static var recordingsRoot: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Working-set requirement (§3): ~2× source size for normalized PCM and
    /// checkpoints, plus fixed slack for exports and the transcript database.
    public static func requiredWorkingBytes(forSourceSize size: Int64) -> Int64 {
        2 * size + 256 * 1024 * 1024
    }

    public static func checkDiskPreconditions(sourceSize: Int64, at url: URL) throws {
        let required = requiredWorkingBytes(forSourceSize: sourceSize)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        if available < required {
            throw LonghandError.insufficientDisk(requiredBytes: required, availableBytes: available)
        }
    }

    public struct ImportedJob: Sendable {
        public var record: JobRecord
        public var files: JobFiles
    }

    /// `securityScoped` is true for document-picker URLs, which need
    /// `startAccessingSecurityScopedResource` around the copy. `location` is
    /// the fix captured at record start; when nil the copy's own embedded
    /// metadata is used. Either way it lands in metadata.json, never exports.
    public static func importRecording(from sourceURL: URL, securityScoped: Bool,
                                declaredLanguage: String?,
                                expectedSpeakerCount: Int?,
                                location: CapturedLocation? = nil,
                                title: String? = nil,
                                sourceTakeID: String? = nil,
                                markers: [TimeInterval] = []) async throws -> ImportedJob {
        if securityScoped {
            guard sourceURL.startAccessingSecurityScopedResource() else {
                throw LonghandError.decodeFailed(reason: "the provider denied access to the file")
            }
        }
        defer { if securityScoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let sourceSize = (attributes[.size] as? Int64) ?? 0
        try checkDiskPreconditions(sourceSize: sourceSize, at: recordingsRoot.deletingLastPathComponent())

        let jobID = UUID()
        let files = JobFiles(recordingsRoot: recordingsRoot, jobID: jobID)
        try files.createDirectory()

        let ext = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension.lowercased()
        let originalURL = files.original(fileExtension: ext)

        // Anything throwing between creating the folder and writing job.json
        // leaves a full copy of the audio in a directory the library cannot
        // list and nothing deletes.
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: files.root) }
        }

        try FileManager.default.copyItem(at: sourceURL, to: originalURL)

        let hash = try sha256(of: originalURL)
        let classification = try FormatAdapterChain.classify(url: originalURL)

        var resolvedLocation = location
        // The setting governs storing a location, not just capturing one.
        if !LocationCapture.isEnabled {
            resolvedLocation = nil
        } else if resolvedLocation == nil {
            resolvedLocation = await embeddedLocation(of: originalURL)
        }
        let metadata = ImportMetadata(
            importedAt: Date(),
            sourceHash: hash,
            sourceFileSize: sourceSize,
            sourceExtension: ext,
            sourceFormat: formatName(of: classification),
            declaredLanguage: declaredLanguage,
            expectedSpeakerCount: expectedSpeakerCount,
            location: resolvedLocation,
            sourceTakeID: sourceTakeID
        )
        try AtomicFile.writeJSON(metadata, to: files.metadata)

        // User-authored content, so it starts life in the overlay rather than
        // in anything the pipeline regenerates.
        if !markers.isEmpty {
            var overlay = UserOverlay()
            for time in markers { overlay.addMarker(at: time) }
            try AtomicFile.writeJSON(overlay, to: files.overlay)
        }

        // Stored, shown, and never logged (§14.3).
        var record = JobRecord(id: jobID,
                               // A take passes a human title; an imported file
                               // keeps the name it arrived with.
                               title: title ?? sourceURL.deletingPathExtension().lastPathComponent,
                               createdAt: Date(),
                               state: .imported,
                               lastCheckpointState: .imported,
                               language: declaredLanguage)
        try AtomicFile.writeJSON(record, to: files.job)
        // From here the job owns its folder, and a later failure is recorded on
        // it rather than deleted.
        completed = true

        // Rejected at import, before any inference (§17), but after the copy so
        // the error and the raw-PCM confirmation path can re-use it.
        if case let .rejected(reason) = classification {
            record.state = .failed
            record.errorDescription = LonghandError.unsupportedMedia(detected: reason, rawPCMCandidate: false).localizedDescription
            try AtomicFile.writeJSON(record, to: files.job)
        }

        return ImportedJob(record: record, files: files)
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func formatName(of classification: FormatProbe.Classification) -> String {
        switch classification {
        case let .container(kind): return kind.rawValue
        case let .mpegElementaryStream(info):
            return "mpegElementaryStream(v\(info.version.rawValue) L\(info.layer.rawValue) \(info.sampleRate) Hz)"
        case .unknown: return "unknown"
        case let .rejected(reason): return "rejected: \(reason)"
        }
    }
}
