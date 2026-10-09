import CoreSpotlight
import Foundation
import LonghandKit
import OSLog
import UniformTypeIdentifiers

/// Recordings in the device's own search, so a phrase from a meeting finds
/// its transcript from the Home Screen or Spotlight without opening the app.
///
/// What goes in: the title, the date, the length, and the transcript's words
/// with their speaker names, read from `transcript.json` so corrections and
/// renames are in. What never goes in: voice profiles, the location, the
/// calendar event, the summary (§14.1 keeps the first three off every
/// boundary; the summary is a model's guess and does not belong in search
/// results that read as fact). The index is Core Spotlight's, on this device,
/// and the Settings toggle clears it in one call.
public enum SpotlightIndex {

    public static let settingsKey = "indexTranscriptsInSpotlight"

    /// On unless turned off: this is what the system's search is for, and
    /// nothing leaves the device.
    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingsKey) as? Bool ?? true
    }

    /// Every item the app has ever indexed hangs off this, so one call
    /// removes them all.
    static let domain = "recordings"

    /// How much of the transcript the result shows under the title.
    static let snippetLength = 240

    private static let log = Logger(subsystem: "com.shpala.Longhand", category: "spotlight")

    /// What one recording contributes, built without the index so the tests
    /// can read it.
    public struct Entry: Equatable, Sendable {
        public var jobID: UUID
        public var title: String
        /// The opening words, shown under the title in the results.
        public var snippet: String
        /// The whole transcript, searched but not shown.
        public var text: String
        public var speakers: [String]
        public var createdAt: Date
        public var duration: TimeInterval?
    }

    /// Nil when the transcript is not readable yet: a job still transcribing
    /// is found by its title alone.
    public static func entry(for record: JobRecord, transcript: Transcript?) -> Entry {
        var lines: [String] = []
        var speakers: [String] = []
        for turn in transcript?.turns ?? [] {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append("\(turn.speaker): \(text)")
            if !speakers.contains(turn.speaker) { speakers.append(turn.speaker) }
        }
        let plain = (transcript?.turns ?? []).map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Entry(jobID: record.id,
                     title: record.title,
                     snippet: snippet(of: plain),
                     text: lines.joined(separator: "\n"),
                     speakers: speakers,
                     createdAt: record.createdAt,
                     duration: record.duration ?? transcript?.duration)
    }

    static func snippet(of text: String) -> String {
        guard text.count > snippetLength else { return text }
        let cut = text.index(text.startIndex, offsetBy: snippetLength)
        // Back to the last word boundary, so the snippet does not end mid-word.
        let head = text[..<cut]
        let trimmed = head.lastIndex(where: { $0.isWhitespace }).map { head[..<$0] } ?? head
        return String(trimmed) + "…"
    }

    /// Reads a job's record and transcript from disk and indexes it. Off the
    /// main thread: a transcript is a file read, and a library is many.
    public static func index(jobIDs: some Collection<UUID>) {
        guard hostIsApp, isEnabled, !jobIDs.isEmpty else { return }
        let ids = Array(jobIDs)
        Task.detached(priority: .utility) {
            var items: [CSSearchableItem] = []
            for id in ids {
                let files = JobStore.files(for: id)
                guard let record = (try? AtomicFile.readJSON(JobRecord.self, from: files.job, stage: "job")) ?? nil else { continue }
                let transcript = (try? AtomicFile.readJSON(Transcript.self, from: files.transcriptJSON, stage: "COMPLETE")) ?? nil
                items.append(item(for: entry(for: record, transcript: transcript)))
            }
            guard !items.isEmpty else { return }
            let count = items.count
            guard CSSearchableIndex.isIndexingAvailable() else {
                log.notice("indexing unavailable on this device; \(count) recordings not indexed")
                return
            }
            CSSearchableIndex.default().indexSearchableItems(items) { error in
                if let error {
                    log.error("indexing \(count) recordings failed: \(error.localizedDescription)")
                } else {
                    log.info("indexed \(count) recordings")
                }
            }
        }
    }

    public static func remove(jobIDs: some Collection<UUID>) {
        guard hostIsApp, !jobIDs.isEmpty else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: jobIDs.map(\.uuidString)) { error in
            if let error { log.error("removing recordings from the index failed: \(error.localizedDescription)") }
        }
    }

    /// The whole library, for a launch or for the setting being turned on.
    public static func reindexAll() {
        guard hostIsApp, isEnabled else { return }
        index(jobIDs: JobStore.allJobs().map(\.record.id))
    }

    /// The setting being turned off.
    public static func removeAll() {
        guard hostIsApp else { return }
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
    }

    /// The recording behind a tapped result, from the activity the system
    /// hands the app.
    public static func jobID(from activity: NSUserActivity) -> UUID? {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return nil }
        return UUID(uuidString: identifier)
    }

    static func item(for entry: Entry) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = entry.title
        attributes.contentDescription = entry.snippet
        attributes.textContent = entry.text
        attributes.keywords = entry.speakers
        attributes.contentCreationDate = entry.createdAt
        if let duration = entry.duration { attributes.duration = NSNumber(value: duration) }
        let item = CSSearchableItem(uniqueIdentifier: entry.jobID.uuidString,
                                    domainIdentifier: domain,
                                    attributeSet: attributes)
        // The default is a month, after which the recording would quietly
        // leave search while still in the library.
        item.expirationDate = .distantFuture
        return item
    }

    /// Only the apps index. The packages' tests run in a test host, and a
    /// test fixture in the Mac's Spotlight would be a surprise.
    static var hostIsApp: Bool {
        Bundle.main.bundleIdentifier?.hasPrefix("com.shpala.Longhand") == true
    }
}
