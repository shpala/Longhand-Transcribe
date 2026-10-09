import EventKit
import LonghandKit

/// The calendar event a take is being recorded during, for its title and for
/// the names of the people in the room. Read once at record start, like the
/// location, and kept in metadata.json only.
///
/// Deliberate non-features: nothing is written to the calendar, no event is
/// created for a take, and the attendee names go no further than the speaker
/// rename sheet, where they are offered, never applied. A take that overlaps
/// no event gets the usual dated title.
public nonisolated enum CalendarContext {

    public static let settingsKey = "useCalendarForTitles"

    /// The Settings toggle. **Off unless asked for**, like location: reading
    /// the calendar is a permission the user should decide on, and a title
    /// taken from a private event is a surprise nobody opted into.
    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingsKey) as? Bool ?? false
    }

    /// How far either side of now an event may sit and still be "this
    /// meeting": a take often starts a few minutes before the slot, and runs
    /// past its end.
    static let leadTolerance: TimeInterval = 15 * 60
    static let lagTolerance: TimeInterval = 15 * 60

    /// Asks for calendar access the first time, then finds the event in
    /// progress. Nil on denial, on no event, and on anything going wrong: the
    /// take must never wait on the calendar.
    public static func current(at now: Date = Date()) async -> CalendarEventContext? {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .notDetermined:
            guard (try? await store.requestFullAccessToEvents()) == true else { return nil }
        case .fullAccess:
            break
        default:
            // Write-only access cannot read events, and denial is a decision.
            return nil
        }
        let window = store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600),
                                              end: now.addingTimeInterval(lagTolerance),
                                              calendars: nil)
        let events = store.events(matching: window)
        return pick(from: events.map(Candidate.init), at: now)
    }

    /// What `pick` needs of an event, so the choice can be tested without a
    /// calendar.
    struct Candidate {
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var attendees: [String]

        init(title: String, start: Date, end: Date, isAllDay: Bool = false, attendees: [String] = []) {
            self.title = title
            self.start = start
            self.end = end
            self.isAllDay = isAllDay
            self.attendees = attendees
        }

        init(_ event: EKEvent) {
            title = event.title ?? ""
            start = event.startDate
            end = event.endDate
            isAllDay = event.isAllDay
            // The user is a speaker already; the point is the other people.
            var names: [String] = []
            for participant in event.attendees ?? [] where !participant.isCurrentUser {
                if let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty, !names.contains(name) {
                    names.append(name)
                }
            }
            if let organizer = event.organizer, !organizer.isCurrentUser,
               let name = organizer.name?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty, !names.contains(name) {
                names.append(name)
            }
            attendees = names
        }
    }

    /// The event in progress, allowing a take that starts a little early or
    /// runs a little late. All-day events are not meetings. Among several
    /// (an overlapping "Focus time" block), the one that started most
    /// recently is the one being attended.
    static func pick(from candidates: [Candidate], at now: Date) -> CalendarEventContext? {
        let live = candidates.filter { event in
            !event.isAllDay
                && !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && event.start <= now.addingTimeInterval(leadTolerance)
                && event.end >= now.addingTimeInterval(-lagTolerance)
        }
        guard let chosen = live.max(by: { $0.start < $1.start }) else { return nil }
        return CalendarEventContext(title: chosen.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                    attendees: chosen.attendees,
                                    startDate: chosen.start)
    }
}
