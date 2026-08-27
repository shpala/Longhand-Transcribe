import Foundation

/// Per-job file layout (§10.1). Working files (normalized PCM, temp enrollment
/// clips) are transient and deleted per §13.4; everything listed here is durable.
public struct JobFiles: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public init(recordingsRoot: URL, jobID: UUID) {
        self.root = recordingsRoot.appendingPathComponent(jobID.uuidString, isDirectory: true)
    }

    public func original(fileExtension: String) -> URL {
        root.appendingPathComponent("original.\(fileExtension)")
    }

    /// Locates the original regardless of its extension.
    public func findOriginal() -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        return items.first { $0.deletingPathExtension().lastPathComponent == "original" }
    }

    public var job: URL { root.appendingPathComponent("job.json") }
    public var metadata: URL { root.appendingPathComponent("metadata.json") }
    public var asr: URL { root.appendingPathComponent("10_asr.json") }
    public var diarization: URL { root.appendingPathComponent("20_diarization.json") }
    public var mergedWords: URL { root.appendingPathComponent("30_merged_words.json") }
    public var identity: URL { root.appendingPathComponent("40_identity.json") }
    /// User-authored content: renames, text edits, speaker reassignments,
    /// markers. Deliberately NOT a numbered checkpoint: those are pipeline
    /// stage artifacts, gated on existence and deleted by a re-transcribe.
    /// This one outlives every re-run (§13.2).
    public var overlay: URL { root.appendingPathComponent("overlay.json") }

    public var transcriptJSON: URL { root.appendingPathComponent("transcript.json") }
    public var transcriptMarkdown: URL { root.appendingPathComponent("transcript.md") }
    public var transcriptText: URL { root.appendingPathComponent("transcript.txt") }

    /// Largest transient artifact; deleted when the job reaches COMPLETE (§13.4).
    public var normalizedPCM: URL { root.appendingPathComponent("working-normalized.wav") }

    public func createDirectory() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Working files that are not the normalized PCM: an interrupted
    /// quiet-boost pass leaves a `gain-<uuid>.wav` behind, and nothing else
    /// ever collects it.
    public func strayWorkingFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return contents
            .filter { $0.hasPrefix("gain-") && $0.hasSuffix(".wav") }
            .map { root.appendingPathComponent($0) }
    }

    public func deleteTransientArtifacts() {
        try? FileManager.default.removeItem(at: normalizedPCM)
    }
}

/// Atomic checkpoint I/O (§10.1): write to a temp path and rename, so a
/// termination mid-write cannot leave a truncated checkpoint that resume logic
/// would trust. Reads that fail to decode are treated as absent checkpoints.
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    public static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(try encoder.encode(value), to: url)
    }

    /// Returns nil when the file is missing; throws `checkpointCorrupt` when it
    /// exists but cannot be decoded (truncated write, schema drift).
    public static func readJSON<T: Decodable>(_ type: T.Type, from url: URL, stage: String) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LonghandError.checkpointCorrupt(stage: stage)
        }
    }
}
