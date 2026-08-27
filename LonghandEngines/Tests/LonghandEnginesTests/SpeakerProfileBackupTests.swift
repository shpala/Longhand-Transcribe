import Foundation
import Testing
import LonghandKit
@testable import LonghandEngines

/// Enrolled voices stay out of backups (§14.1). Run against a scratch file so
/// the test never touches the real store on the machine running it.
struct SpeakerProfileBackupTests {

    @Test func aWrittenProfileFileIsExcludedFromBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("speaker-profiles.json")
        try AtomicFile.writeJSON([SpeakerProfile](), to: url)

        #expect(SpeakerProfileStore.excludeFromBackup(url))
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    /// `load` calls this on every read, including before anyone has enrolled.
    @Test func noFileIsNotAnErrorAndCreatesNothing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("profiles-absent-\(UUID()).json")
        #expect(!SpeakerProfileStore.excludeFromBackup(url))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
