import Foundation

/// Identifies a calendar the way users write it in the config: by account (EventKit source)
/// title and calendar title.
public struct CalendarRef: Hashable, Codable, Sendable, CustomStringConvertible {
    public var account: String
    public var calendar: String

    public init(account: String, calendar: String) {
        self.account = account
        self.calendar = calendar
    }

    public var description: String { "\(account) / \(calendar)" }
}

/// A calendar that is part of the sync set, resolved against the underlying store.
public struct SyncCalendar: Hashable, Sendable {
    public var ref: CalendarRef
    /// Opaque, deterministic key used inside hold markers so that no calendar or account
    /// name is written onto another calendar.
    public var key: String
    public var isWritable: Bool
    public var supportsBusyAvailability: Bool
    /// Short label prefixed to copied titles on calendars that receive details, e.g. "[Acme]".
    public var label: String?
    /// When true, holds on this calendar carry the source event's title, location, URL and notes
    /// instead of being bare "Hold" events.
    public var receivesDetails: Bool

    public init(ref: CalendarRef, isWritable: Bool = true, supportsBusyAvailability: Bool = true,
                label: String? = nil, receivesDetails: Bool = false) {
        self.ref = ref
        self.key = HoldMarker.calendarKey(for: ref)
        self.isWritable = isWritable
        self.supportsBusyAvailability = supportsBusyAvailability
        self.label = label
        self.receivesDetails = receivesDetails
    }
}

/// Everything `list-calendars` prints for one calendar.
public struct CalendarInfo: Hashable, Sendable {
    public var account: String
    public var accountType: String
    public var calendar: String
    public var identifier: String
    public var isWritable: Bool
    public var isSubscribed: Bool

    public init(account: String, accountType: String, calendar: String, identifier: String,
                isWritable: Bool, isSubscribed: Bool) {
        self.account = account
        self.accountType = accountType
        self.calendar = calendar
        self.identifier = identifier
        self.isWritable = isWritable
        self.isSubscribed = isSubscribed
    }
}

public enum Availability: String, Sendable {
    case notSupported, busy, free, tentative, unavailable
}

public enum EventStatus: String, Sendable {
    case none, confirmed, tentative, canceled
}

/// The current user's participation status on an event they were invited to.
public enum Participation: String, Sendable {
    case notAnAttendee, unknown, pending, accepted, declined, tentative, other
}

/// A store-agnostic snapshot of one event occurrence.
public struct CalendarEvent: Hashable, Sendable {
    /// Store-specific identifier used to update or delete this event.
    public var id: String
    public var calendar: CalendarRef
    /// Server-side identifier (iCalendar UID). Stable across devices and reinstalls.
    public var externalID: String
    /// For occurrences of a recurring event: the occurrence's original start date.
    /// `nil` for non-recurring events.
    public var occurrenceDate: Date?
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var title: String
    public var location: String?
    public var url: String?
    public var notes: String?
    public var availability: Availability
    public var status: EventStatus
    public var participation: Participation

    public init(id: String, calendar: CalendarRef, externalID: String, occurrenceDate: Date? = nil,
                start: Date, end: Date, isAllDay: Bool = false, title: String, location: String? = nil,
                url: String? = nil, notes: String? = nil, availability: Availability = .busy,
                status: EventStatus = .confirmed, participation: Participation = .notAnAttendee) {
        self.id = id
        self.calendar = calendar
        self.externalID = externalID
        self.occurrenceDate = occurrenceDate
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.title = title
        self.location = location
        self.url = url
        self.notes = notes
        self.availability = availability
        self.status = status
        self.participation = participation
    }
}

/// The source details copied onto a hold on a calendar that receives details.
public struct HoldDetails: Hashable, Sendable {
    public var title: String
    public var location: String?
    public var url: String?
    public var notes: String?
    /// Short hash of the copied content, stored in the marker so that a later run can tell
    /// whether the source changed without comparing text the server may have reformatted.
    public var hash: String

    public init(title: String, location: String?, url: String?, notes: String?) {
        self.title = title
        self.location = Self.clean(location)
        self.url = Self.clean(url)
        self.notes = Self.clean(notes)
        self.hash = HoldMarker.shortHash([title, self.location ?? "", self.url ?? "", self.notes ?? ""]
            .joined(separator: "\u{1F}"))
    }

    private static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// What a hold should look like when created or updated.
public struct HoldSpec: Hashable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var marker: HoldMarker
    /// Present only for holds on a calendar that receives details.
    public var details: HoldDetails?

    public init(title: String, start: Date, end: Date, marker: HoldMarker, details: HoldDetails? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.marker = marker
        self.details = details
    }

    public var location: String? { details?.location }
    public var url: String? { details?.url }

    /// The full notes text written onto the hold. For bare holds this is only the marker and a
    /// generic explanation; for detailed copies the source notes come first.
    public var notes: String {
        guard let details else { return marker.notesText }
        var text = details.notes ?? ""
        if !text.isEmpty { text += "\n\n" }
        return text + marker.detailedNotesText
    }
}
