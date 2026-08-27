import Foundation
import LonghandKit

/// Local store for enrolled voices (§9.2, §14.1): embeddings live in one JSON
/// file inside Application Support, are never exported, and support complete
/// deletion. Enrollment is always an explicit user action, never automatic
/// from an AI prediction (§9.2).
public nonisolated enum SpeakerProfileStore {

    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("speaker-profiles.json")
    }

    public static func load() -> [SpeakerProfile] {
        // Also here, not only in `save`, so a file written before the flag
        // existed is covered without waiting for the next enrollment.
        excludeFromBackup()
        return (try? AtomicFile.readJSON([SpeakerProfile].self, from: fileURL, stage: "profiles")) ?? []
    }

    public static func save(_ profiles: [SpeakerProfile]) {
        try? AtomicFile.writeJSON(profiles, to: fileURL)
        // After every write: the atomic replace swaps in a new file, and
        // whether the old one's flag carries over is not something to rely on.
        excludeFromBackup()
    }

    /// §14.1 keeps embeddings on the device, and a backup is a copy that
    /// leaves it: iCloud on iOS, Time Machine on the Mac. It is also a copy
    /// `deleteAll` cannot reach, so "complete deletion" would be untrue for as
    /// long as an old backup survived. The cost is that voices must be enrolled
    /// again after restoring onto a new device.
    ///
    /// Data protection stays at the system default (until first unlock) on
    /// purpose. The identify stage reads this file from a background job that
    /// often runs with the phone locked, and `load` reads an unreadable file as
    /// no profiles: under `.complete` a locked run would silently match no one,
    /// and an enrollment made then would save over every voice but the new one.
    @discardableResult
    static func excludeFromBackup(_ url: URL = fileURL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        return (try? url.setResourceValues(values)) != nil
    }

    /// Adds an embedding to the profile with this display name (creating one
    /// if needed). Multi-sample enrollment per §9.2.
    public static func enroll(displayName: String, embedding: [Float], modelIdentifier: String) {
        var profiles = load()
        if let index = profiles.firstIndex(where: {
            $0.displayName == displayName && $0.modelIdentifier == modelIdentifier
        }) {
            profiles[index].embeddings.append(embedding)
            profiles[index].updatedAt = Date()
        } else {
            profiles.append(SpeakerProfile(displayName: displayName,
                                           modelIdentifier: modelIdentifier,
                                           embeddings: [embedding],
                                           createdAt: Date(), updatedAt: Date()))
        }
        save(profiles)
    }

    public static func delete(id: UUID) {
        save(load().filter { $0.id != id })
    }

    /// §14.1: complete deletion of all biometric-like data.
    public static func deleteAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
