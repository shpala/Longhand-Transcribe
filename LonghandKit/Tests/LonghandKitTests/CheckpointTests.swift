import Foundation
import Testing
@testable import LonghandKit

@Suite struct CheckpointTests {

    private func temporaryJobFiles() throws -> JobFiles {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("longhand-tests-\(UUID().uuidString)", isDirectory: true)
        let files = JobFiles(root: root)
        try files.createDirectory()
        return files
    }

    @Test func writeAndReadCheckpointRoundTrips() throws {
        let files = try temporaryJobFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }

        let result = ASRResult(language: "en", engine: "test", modelIdentifier: "test/fixture",
                               segments: [ASRSegment(id: 0, start: 0, end: 1, text: "hi",
                                                     words: [ASRWord(text: "hi", start: 0, end: 1)])])
        try AtomicFile.writeJSON(result, to: files.asr)
        let loaded = try AtomicFile.readJSON(ASRResult.self, from: files.asr, stage: "TRANSCRIBED")
        #expect(loaded == result)
    }

    @Test func missingCheckpointReadsAsNil() throws {
        let files = try temporaryJobFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let loaded = try AtomicFile.readJSON(ASRResult.self, from: files.asr, stage: "TRANSCRIBED")
        #expect(loaded == nil)
    }

    @Test func truncatedCheckpointIsNotTrusted() throws {
        // §18.2: terminate mid-checkpoint-write and assert no truncated
        // checkpoint is trusted on resume. Simulate the truncation directly.
        let files = try temporaryJobFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }

        let result = ASRResult(language: "en", engine: "test", modelIdentifier: "test/fixture", segments: [])
        let full = try JSONEncoder().encode(result)
        try full.prefix(full.count / 2).write(to: files.asr)

        #expect(throws: LonghandError.checkpointCorrupt(stage: "TRANSCRIBED")) {
            _ = try AtomicFile.readJSON(ASRResult.self, from: files.asr, stage: "TRANSCRIBED")
        }
    }

    @Test func atomicWriteReplacesExistingContent() throws {
        let files = try temporaryJobFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }

        try AtomicFile.write(Data("old".utf8), to: files.metadata)
        try AtomicFile.write(Data("new".utf8), to: files.metadata)
        #expect(try Data(contentsOf: files.metadata) == Data("new".utf8))
        // No temp files left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: files.root.path)
            .filter { $0.hasPrefix(".tmp-") }
        #expect(leftovers.isEmpty)
    }

    @Test func transientArtifactsAreDeletable() throws {
        // §13.4: normalized PCM is a working artifact deleted at COMPLETE.
        let files = try temporaryJobFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }

        try Data(repeating: 0, count: 1024).write(to: files.normalizedPCM)
        try AtomicFile.write(Data("{}".utf8), to: files.metadata)
        files.deleteTransientArtifacts()
        #expect(!FileManager.default.fileExists(atPath: files.normalizedPCM.path))
        // Durable artifacts stay (§13.4: checkpoints make reprocessing deterministic).
        #expect(FileManager.default.fileExists(atPath: files.metadata.path))
    }
}
