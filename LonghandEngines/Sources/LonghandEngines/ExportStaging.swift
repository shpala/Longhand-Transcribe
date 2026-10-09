import Foundation
import LonghandKit

/// A copy of an export under the name it should travel by. The job folder
/// keeps `transcript.md`; the share sheet, AirDrop and Mail show the copy's
/// name, so the copy is named after the recording (`ExportNaming`).
///
/// Staged under the temporary directory, one folder per call so two shares
/// of the same name cannot collide, and swept on the next staging and at
/// launch: iOS clears `tmp/` on its own schedule, and a stale copy of a
/// transcript is still a transcript.
public nonisolated enum ExportStaging {

    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    /// The staged copy's URL. Throws when the copy cannot be made, which the
    /// caller reports as a failed export rather than sharing the wrong file.
    public static func stagedCopy(of url: URL, title: String, kind: ExportNaming.Kind) throws -> URL {
        sweep()
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(ExportNaming.fileName(title: title, kind: kind))
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// Removes every earlier staged copy. A share sheet that is still open
    /// holds its own reference to the file it was given.
    public static func sweep() {
        try? FileManager.default.removeItem(at: root)
    }
}
