import EventKit
import Foundation
import ImBusyCore

public enum EventKitStoreError: Error, CustomStringConvertible {
    case calendarNotFound(Config.CalendarEntry, suggestions: [CalendarInfo])
    case ambiguousCalendar(Config.CalendarEntry, matches: [CalendarInfo])
    case eventNotFound(String)
    case invalidURL

    public var description: String {
        switch self {
        case .calendarNotFound(let entry, let suggestions):
            var text = "calendar \"\(entry.ref)\" not found"
            if let id = entry.calendarIdentifier { text += " (identifier \(id))" }
            if !suggestions.isEmpty {
                text += ". Did you mean: " + suggestions.map { "\"\($0.account) / \($0.calendar)\"" }.joined(separator: ", ")
            }
            return text + ". Run `imbusy list-calendars` to see exact names."
        case .ambiguousCalendar(let entry, let matches):
            return "calendar \"\(entry.ref)\" matches \(matches.count) calendars. Add \"calendarIdentifier\" to the "
                + "config entry with one of: " + matches.map(\.identifier).joined(separator: ", ")
        case .eventNotFound(let id):
            return "event \(id) is no longer available"
        case .invalidURL:
            return "could not build probe URL"
        }
    }
}

/// `CalendarStore` backed by EventKit.
public final class EventKitStore: CalendarStore {
    public let store: EKEventStore
    private var ekCalendars: [CalendarRef: EKCalendar] = [:]
    private var ekEvents: [String: EKEvent] = [:]

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    // MARK: Calendars

    public func allCalendars() throws -> [CalendarInfo] {
        store.calendars(for: .event).map(Self.info(for:)).sorted {
            ($0.account, $0.calendar) < ($1.account, $1.calendar)
        }
    }

    public func resolve(_ entry: Config.CalendarEntry) throws -> SyncCalendar {
        let all = store.calendars(for: .event)
        let matches: [EKCalendar]
        if let id = entry.calendarIdentifier {
            matches = all.filter { $0.calendarIdentifier == id }
        } else {
            matches = all.filter {
                Self.normalize($0.source?.title) == Self.normalize(entry.account)
                    && Self.normalize($0.title) == Self.normalize(entry.calendar)
            }
        }
        guard let calendar = matches.first else {
            let suggestions = all.filter {
                Self.normalize($0.title) == Self.normalize(entry.calendar)
                    || Self.normalize($0.source?.title) == Self.normalize(entry.account)
            }
            throw EventKitStoreError.calendarNotFound(entry, suggestions: suggestions.map(Self.info(for:)))
        }
        guard matches.count == 1 else {
            throw EventKitStoreError.ambiguousCalendar(entry, matches: matches.map(Self.info(for:)))
        }
        ekCalendars[entry.ref] = calendar
        return SyncCalendar(ref: entry.ref,
                            isWritable: calendar.allowsContentModifications,
                            supportsBusyAvailability: calendar.supportedEventAvailabilities.contains(.busy),
                            label: entry.label,
                            receivesDetails: entry.receivesDetails ?? false)
    }

    private static func normalize(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func info(for calendar: EKCalendar) -> CalendarInfo {
        CalendarInfo(account: calendar.source?.title ?? "(no account)",
                     accountType: typeName(calendar.source?.sourceType),
                     calendar: calendar.title,
                     identifier: calendar.calendarIdentifier,
                     isWritable: calendar.allowsContentModifications,
                     isSubscribed: calendar.isSubscribed)
    }

    private static func typeName(_ type: EKSourceType?) -> String {
        switch type {
        case .local: return "Local"
        case .exchange: return "Exchange"
        case .calDAV: return "CalDAV"
        case .mobileMe: return "iCloud"
        case .subscribed: return "Subscribed"
        case .birthdays: return "Birthdays"
        case .none: return "Unknown"
        @unknown default: return "Other"
        }
    }

    private func ekCalendar(for ref: CalendarRef) throws -> EKCalendar {
        guard let calendar = ekCalendars[ref] else {
            throw EventKitStoreError.calendarNotFound(Config.CalendarEntry(account: ref.account, calendar: ref.calendar),
                                                      suggestions: [])
        }
        return calendar
    }

    // MARK: Events

    public func events(in calendar: SyncCalendar, from: Date, to: Date) throws -> [CalendarEvent] {
        let ekCalendar = try ekCalendar(for: calendar.ref)
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [ekCalendar])
        return store.events(matching: predicate).map { ek in
            let event = Self.convert(ek, calendar: calendar.ref)
            ekEvents[event.id] = ek
            return event
        }
    }

    private static func convert(_ ek: EKEvent, calendar: CalendarRef) -> CalendarEvent {
        let isRecurring = ek.hasRecurrenceRules || ek.isDetached
        let occurrence = isRecurring ? ek.occurrenceDate : nil
        var id = ek.eventIdentifier ?? ""
        if let occurrence { id += "@" + String(Int(occurrence.timeIntervalSince1970)) }
        return CalendarEvent(id: id,
                             calendar: calendar,
                             externalID: ek.calendarItemExternalIdentifier ?? "",
                             occurrenceDate: occurrence,
                             start: ek.startDate,
                             end: ek.endDate,
                             isAllDay: ek.isAllDay,
                             title: ek.title ?? "",
                             location: ek.location,
                             url: ek.url?.absoluteString,
                             notes: ek.notes,
                             availability: availability(ek.availability),
                             status: status(ek.status),
                             participation: participation(ek))
    }

    private static func availability(_ a: EKEventAvailability) -> Availability {
        switch a {
        case .busy: return .busy
        case .free: return .free
        case .tentative: return .tentative
        case .unavailable: return .unavailable
        case .notSupported: return .notSupported
        @unknown default: return .notSupported
        }
    }

    private static func status(_ s: EKEventStatus) -> EventStatus {
        switch s {
        case .none: return .none
        case .confirmed: return .confirmed
        case .tentative: return .tentative
        case .canceled: return .canceled
        @unknown default: return .none
        }
    }

    private static func participation(_ ek: EKEvent) -> Participation {
        guard let attendees = ek.attendees, !attendees.isEmpty else { return .notAnAttendee }
        guard let me = attendees.first(where: { $0.isCurrentUser }) else { return .notAnAttendee }
        switch me.participantStatus {
        case .unknown: return .unknown
        case .pending: return .pending
        case .accepted: return .accepted
        case .declined: return .declined
        case .tentative: return .tentative
        case .delegated, .completed, .inProcess: return .other
        @unknown default: return .other
        }
    }

    // MARK: Mutations

    public func createHold(_ spec: HoldSpec, in calendar: SyncCalendar) throws {
        let ek = EKEvent(eventStore: store)
        ek.calendar = try ekCalendar(for: calendar.ref)
        ek.title = spec.title
        ek.startDate = spec.start
        ek.endDate = spec.end
        ek.isAllDay = false
        ek.alarms = nil
        Self.applyContent(of: spec, to: ek)
        if calendar.supportsBusyAvailability {
            ek.availability = .busy
        }
        try store.save(ek, span: .thisEvent, commit: false)
    }

    public func updateHold(_ event: CalendarEvent, to spec: HoldSpec) throws {
        guard let ek = ekEvents[event.id] else { throw EventKitStoreError.eventNotFound(event.id) }
        ek.startDate = spec.start
        ek.endDate = spec.end
        Self.applyContent(of: spec, to: ek)
        try store.save(ek, span: .thisEvent, commit: false)
    }

    /// Title, notes, location and URL. Never attendees or alarms.
    private static func applyContent(of spec: HoldSpec, to ek: EKEvent) {
        ek.title = spec.title
        ek.notes = spec.notes
        ek.location = spec.location
        ek.url = spec.url.flatMap { URL(string: $0) }
    }

    public func deleteHold(_ event: CalendarEvent) throws {
        guard let ek = ekEvents[event.id] else { throw EventKitStoreError.eventNotFound(event.id) }
        try store.remove(ek, span: .thisEvent, commit: false)
        ekEvents[event.id] = nil
    }

    public func commit() throws {
        try store.commit()
    }

    // MARK: Probe (marker round-trip check)

    public static let probeTitle = "imbusy probe"

    /// Result of reading a probe event back after the server has synced it.
    public struct ProbeResult {
        public var start: Date
        public var notes: String?
        public var url: URL?
    }

    /// Create a free, past-dated test event carrying `text` in both the notes and URL fields.
    public func createProbe(in calendar: SyncCalendar, text: String, start: Date) throws {
        let ek = EKEvent(eventStore: store)
        ek.calendar = try ekCalendar(for: calendar.ref)
        ek.title = Self.probeTitle
        ek.startDate = start
        ek.endDate = start.addingTimeInterval(15 * 60)
        ek.isAllDay = false
        ek.notes = text
        ek.alarms = nil
        ek.availability = .free
        var components = URLComponents(string: "https://imbusy.invalid/probe")
        components?.queryItems = [URLQueryItem(name: "m", value: text)]
        guard let url = components?.url else { throw EventKitStoreError.invalidURL }
        ek.url = url
        try store.save(ek, span: .thisEvent, commit: true)
    }

    public func probes(in calendar: SyncCalendar, from: Date, to: Date) throws -> [ProbeResult] {
        let ekCalendar = try ekCalendar(for: calendar.ref)
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [ekCalendar])
        return store.events(matching: predicate)
            .filter { $0.title == Self.probeTitle }
            .map { ProbeResult(start: $0.startDate, notes: $0.notes, url: $0.url) }
    }

    public func deleteProbes(in calendar: SyncCalendar, from: Date, to: Date) throws -> Int {
        let ekCalendar = try ekCalendar(for: calendar.ref)
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [ekCalendar])
        let probes = store.events(matching: predicate).filter { $0.title == Self.probeTitle }
        for probe in probes {
            try store.remove(probe, span: .thisEvent, commit: false)
        }
        try store.commit()
        return probes.count
    }
}

// MARK: - Authorization

public enum CalendarAccess {
    public enum Status {
        case notDetermined, denied, restricted, fullAccess, writeOnly, unknown
    }

    public static func status() -> Status {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        default: return .unknown
        }
    }

    /// Show the system prompt (if not yet decided) and return whether full access was granted.
    public static func requestFullAccess(store: EKEventStore) async throws -> Bool {
        let granted = try await store.requestFullAccessToEvents()
        if granted {
            // EventKit recommends refreshing the store after authorization changes.
            store.reset()
        }
        return granted
    }
}
