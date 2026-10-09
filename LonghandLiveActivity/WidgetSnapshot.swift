import Foundation

// Compiled into the iOS app and its widget extension. The app writes, the
// widget reads: an extension has no view of the app's own Documents, so the
// library is mirrored into the App Group container as a small file holding
// only what the widget shows. Nothing here may import an iOS-only framework
// beyond Foundation.

/// The library as the Home Screen widget sees it: the latest few recordings
/// by title, date and state. No transcript text, no audio, no location.
struct WidgetSnapshot: Codable, Equatable {

    struct Recording: Codable, Equatable, Identifiable {
        var id: UUID
        var title: String
        var date: Date
        var status: Status
        var duration: TimeInterval?
    }

    enum Status: String, Codable {
        case complete, working, paused, failed
    }

    var recordings: [Recording]
    var updatedAt: Date

    static let groupID = "group.com.shpala.Longhand"
    /// The recent-recordings widget's kind, for timeline reloads.
    static let kind = "com.shpala.Longhand.recent"
    /// How many the largest family shows; the app writes no more.
    static let limit = 6

    /// Under Application Support in the group container, where a file the
    /// app maintains belongs, and where the device tooling can read it: the
    /// container's root is off limits to `devicectl device copy`.
    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("widget-snapshot.json")
    }

    static func read() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func write() throws {
        guard let url = Self.fileURL else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    // The links a widget tap opens. The scheme is the app's own; the library
    // reads these in `onOpenURL` beside the files other apps share in.
    static let recordURL = URL(string: "longhand://record")!

    static func url(opening id: UUID) -> URL {
        URL(string: "longhand://open/\(id.uuidString)")!
    }

    /// The recording a `longhand://open/<id>` link names, if it is one.
    static func jobID(from url: URL) -> UUID? {
        guard url.scheme == "longhand", url.host == "open" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    static func isRecordLink(_ url: URL) -> Bool {
        url.scheme == "longhand" && url.host == "record"
    }
}
