import Foundation

/// The narrow interface the reconciler needs from a calendar backend. Implemented by
/// `EventKitStore` for real use and by an in-memory fake in the tests.
public protocol CalendarStore {
    /// Every calendar the backend can see, for `list-calendars`.
    func allCalendars() throws -> [CalendarInfo]

    /// Resolve a config entry to a calendar in the sync set.
    func resolve(_ entry: Config.CalendarEntry) throws -> SyncCalendar

    /// All event occurrences on `calendar` overlapping the window. Recurring events are expanded.
    func events(in calendar: SyncCalendar, from: Date, to: Date) throws -> [CalendarEvent]

    func createHold(_ spec: HoldSpec, in calendar: SyncCalendar) throws
    /// Bring an existing hold in line with `spec`: times, title, notes, location and URL.
    func updateHold(_ event: CalendarEvent, to spec: HoldSpec) throws
    func deleteHold(_ event: CalendarEvent) throws

    /// Persist all pending changes.
    func commit() throws
}
