import Foundation
@testable import ImBusyCore

/// In-memory `CalendarStore` for tests.
final class FakeCalendarStore: CalendarStore {
    struct NotFound: Error {}

    private(set) var calendars: [CalendarRef: SyncCalendar] = [:]
    private(set) var events: [String: CalendarEvent] = [:]
    private var nextID = 1
    private(set) var commits = 0

    func addCalendar(_ ref: CalendarRef, writable: Bool = true, label: String? = nil,
                     receivesDetails: Bool = false) -> SyncCalendar {
        let calendar = SyncCalendar(ref: ref, isWritable: writable, label: label, receivesDetails: receivesDetails)
        calendars[ref] = calendar
        return calendar
    }

    @discardableResult
    func addSource(on ref: CalendarRef, uid: String, start: Date, end: Date, title: String = "Meeting",
                   occurrence: Date? = nil, isAllDay: Bool = false, availability: Availability = .busy,
                   status: EventStatus = .confirmed, participation: Participation = .notAnAttendee,
                   location: String? = nil, url: String? = nil, notes: String? = nil) -> CalendarEvent {
        let id = "src-\(nextID)"
        nextID += 1
        let event = CalendarEvent(id: id, calendar: ref, externalID: uid, occurrenceDate: occurrence,
                                  start: start, end: end, isAllDay: isAllDay, title: title, location: location,
                                  url: url, notes: notes, availability: availability, status: status,
                                  participation: participation)
        events[id] = event
        return event
    }

    /// Add an event whose notes carry an arbitrary marker text (to simulate holds from elsewhere).
    @discardableResult
    func addRaw(on ref: CalendarRef, uid: String, start: Date, end: Date, title: String, notes: String?) -> CalendarEvent {
        let id = "raw-\(nextID)"
        nextID += 1
        let event = CalendarEvent(id: id, calendar: ref, externalID: uid, start: start, end: end, title: title, notes: notes)
        events[id] = event
        return event
    }

    func remove(_ event: CalendarEvent) {
        events[event.id] = nil
    }

    func modify(_ event: CalendarEvent, _ change: (inout CalendarEvent) -> Void) {
        var copy = events[event.id]!
        change(&copy)
        events[event.id] = copy
    }

    func holds(on ref: CalendarRef) -> [CalendarEvent] {
        events.values
            .filter { $0.calendar == ref && HoldMarker.classify($0.notes) != .source }
            .sorted { $0.start < $1.start }
    }

    func sources(on ref: CalendarRef) -> [CalendarEvent] {
        events.values.filter { $0.calendar == ref && HoldMarker.classify($0.notes) == .source }
    }

    // MARK: CalendarStore

    func allCalendars() throws -> [CalendarInfo] {
        calendars.values.map {
            CalendarInfo(account: $0.ref.account, accountType: "Fake", calendar: $0.ref.calendar,
                         identifier: $0.key, isWritable: $0.isWritable, isSubscribed: false)
        }
    }

    func resolve(_ entry: Config.CalendarEntry) throws -> SyncCalendar {
        guard let calendar = calendars[entry.ref] else { throw NotFound() }
        return calendar
    }

    func events(in calendar: SyncCalendar, from: Date, to: Date) throws -> [CalendarEvent] {
        events.values.filter { $0.calendar == calendar.ref && $0.end > from && $0.start < to }
    }

    func createHold(_ spec: HoldSpec, in calendar: SyncCalendar) throws {
        precondition(calendar.isWritable, "attempted to write to a read-only calendar")
        let id = "hold-\(nextID)"
        nextID += 1
        events[id] = CalendarEvent(id: id, calendar: calendar.ref, externalID: "uid-\(id)", start: spec.start,
                                   end: spec.end, title: spec.title, location: spec.location, url: spec.url,
                                   notes: spec.notes, availability: .busy)
    }

    func updateHold(_ event: CalendarEvent, to spec: HoldSpec) throws {
        guard var existing = events[event.id] else { throw NotFound() }
        existing.start = spec.start
        existing.end = spec.end
        existing.title = spec.title
        existing.location = spec.location
        existing.url = spec.url
        existing.notes = spec.notes
        events[event.id] = existing
    }

    func deleteHold(_ event: CalendarEvent) throws {
        guard events.removeValue(forKey: event.id) != nil else { throw NotFound() }
    }

    func commit() throws {
        commits += 1
    }
}
