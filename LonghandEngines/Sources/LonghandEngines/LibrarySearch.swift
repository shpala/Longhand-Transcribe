import Foundation
import Observation
import LonghandKit

/// Searching across every transcript in the library.
///
/// No persisted index: it is the only thing that would scale to a huge corpus,
/// and also the only thing that breaks §14.1's complete deletion, since
/// `JobStore.delete` removes a job folder and anything inside one goes with it.
/// At personal scale a scan of `transcript.json` is quick, and the parse is
/// cached against the file's modification date, which a rerender bumps.
///
/// Not `@Observable`: the only stored property is that cache, and observing it
/// is an infinite render loop on macOS, where `MacLibraryView` computes
/// `searchResults` inside `body`.
@MainActor
public final class LibrarySearch {

    public struct Result: Identifiable, Sendable {
        public let jobID: UUID
        /// The recording's own name matched, independent of its contents.
        public let titleMatched: Bool
        public let hitCount: Int
        /// First matching passage, for the row.
        public let snippet: String?
        /// Where to jump when the row is opened.
        public let firstHitStart: TimeInterval?

        public var id: UUID { jobID }
    }

    private struct CacheEntry {
        let modified: Date
        let turns: [Transcript.Turn]
    }

    private var cache: [UUID: CacheEntry] = [:]

    public init() {}

    /// Results for the jobs given, in the order given. Jobs with no match are
    /// omitted; an empty query returns nil so callers can show the unfiltered
    /// library rather than an empty one.
    public func results(for query: String, in jobs: [JobRecord]) -> [Result]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // First: §14.1 deletion has to mean the words are gone from memory too.
        invalidate(keeping: Set(jobs.map(\.id)))
        guard !trimmed.isEmpty else { return nil }

        return jobs.compactMap { job in
            let titleMatched = TextFold.contains(trimmed, in: job.title)
            let hits = TranscriptSearch.matches(query: trimmed, in: turns(for: job.id))
            guard titleMatched || !hits.isEmpty else { return nil }
            return Result(jobID: job.id,
                          titleMatched: titleMatched,
                          hitCount: hits.count,
                          snippet: hits.first?.snippet,
                          firstHitStart: hits.first?.start)
        }
    }

    /// Rewrites the dictionary only when something actually goes: this runs on
    /// every `results` call, which on macOS is every pass through the library's
    /// `body`.
    public func invalidate(keeping jobIDs: Set<UUID>) {
        guard cache.keys.contains(where: { !jobIDs.contains($0) }) else { return }
        cache = cache.filter { jobIDs.contains($0.key) }
    }

    private func turns(for jobID: UUID) -> [Transcript.Turn] {
        let url = JobStore.files(for: jobID).transcriptJSON
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let entry = cache[jobID], entry.modified == modified {
            return entry.turns
        }
        let transcript = (try? AtomicFile.readJSON(Transcript.self, from: url, stage: "COMPLETE")) ?? nil
        let turns = transcript?.turns ?? []
        cache[jobID] = CacheEntry(modified: modified, turns: turns)
        return turns
    }
}
