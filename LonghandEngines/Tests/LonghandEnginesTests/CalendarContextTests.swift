import Foundation
import Testing
@testable import LonghandEngines

/// Which calendar event a take belongs to, decided without a calendar.
@Suite struct CalendarContextTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ title: String, from: TimeInterval, to: TimeInterval,
                       allDay: Bool = false, attendees: [String] = []) -> CalendarContext.Candidate {
        CalendarContext.Candidate(title: title, start: now.addingTimeInterval(from),
                                  end: now.addingTimeInterval(to), isAllDay: allDay, attendees: attendees)
    }

    @Test func theEventInProgressNamesTheTake() {
        let picked = CalendarContext.pick(from: [
            event("Weekly sync", from: -600, to: 1800, attendees: ["Dana", "Noam"]),
        ], at: now)
        #expect(picked?.title == "Weekly sync")
        #expect(picked?.attendees == ["Dana", "Noam"])
        #expect(picked?.startDate == now.addingTimeInterval(-600))
    }

    @Test func aTakeStartedALittleEarlyOrLateStillCounts() {
        #expect(CalendarContext.pick(from: [event("Soon", from: 600, to: 2400)], at: now)?.title == "Soon")
        #expect(CalendarContext.pick(from: [event("Just ended", from: -3600, to: -600)], at: now)?.title == "Just ended")
        #expect(CalendarContext.pick(from: [event("Too far off", from: 1800, to: 3600)], at: now) == nil)
        #expect(CalendarContext.pick(from: [event("Long over", from: -7200, to: -1800)], at: now) == nil)
    }

    @Test func allDayAndUntitledEventsAreNotMeetings() {
        #expect(CalendarContext.pick(from: [event("Holiday", from: -36000, to: 50000, allDay: true)], at: now) == nil)
        #expect(CalendarContext.pick(from: [event("   ", from: -600, to: 1800)], at: now) == nil)
    }

    /// A focus block spanning the afternoon and a meeting inside it: the one
    /// that started most recently is the one being attended.
    @Test func theMostRecentlyStartedOfOverlappingEventsWins() {
        let picked = CalendarContext.pick(from: [
            event("Focus time", from: -7200, to: 7200),
            event("Design review", from: -300, to: 2400),
        ], at: now)
        #expect(picked?.title == "Design review")
    }
}
