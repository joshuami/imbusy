import Foundation

/// Settings that affect classification and hold creation.
public struct SyncSettings: Hashable, Sendable {
    public var holdTitle: String
    public var skipAllDay: Bool
    public var skipTentative: Bool
    public var skipUnaccepted: Bool
    public var skipTitleKeywords: [String]

    public init(holdTitle: String = Config.defaultHoldTitle, skipAllDay: Bool = true, skipTentative: Bool = false,
                skipUnaccepted: Bool = false, skipTitleKeywords: [String] = []) {
        self.holdTitle = holdTitle
        self.skipAllDay = skipAllDay
        self.skipTentative = skipTentative
        self.skipUnaccepted = skipUnaccepted
        self.skipTitleKeywords = skipTitleKeywords
    }

    public init(config: Config) {
        self.init(holdTitle: config.holdTitle, skipAllDay: config.skipAllDay, skipTentative: config.skipTentative,
                  skipUnaccepted: config.skipUnaccepted, skipTitleKeywords: config.skipTitleKeywords)
    }

    /// True if `title` contains `keyword` as a whole word, ignoring case.
    public static func titleMatches(_ title: String, keyword: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: keyword.trimmingCharacters(in: .whitespaces))
        guard !escaped.isEmpty,
              let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])",
                                                   options: [.caseInsensitive])
        else { return false }
        return regex.firstMatch(in: title, range: NSRange(title.startIndex..<title.endIndex, in: title)) != nil
    }
}

public enum SkipReason: String, Hashable, Sendable {
    case declined
    case free
    case canceled
    case allDay = "all-day"
    case tentative
    case notAccepted = "not accepted"
    case keyword = "title keyword"
    case noIdentifier = "no identifier"
    case invalidTimes = "invalid times"
}

public enum DeleteReason: String, Hashable, Sendable {
    case orphaned = "source missing or no longer qualifies"
    case duplicate = "duplicate hold"
    case malformed = "unreadable marker"
    case purge = "purge"
}

public struct HoldCreate: Hashable, Sendable {
    public var target: SyncCalendar
    public var spec: HoldSpec
    public var source: CalendarEvent
}

public struct HoldUpdate: Hashable, Sendable {
    public var existing: CalendarEvent
    public var spec: HoldSpec
    public var changes: [String]
}

public struct HoldDelete: Hashable, Sendable {
    public var existing: CalendarEvent
    public var reason: DeleteReason
}

public struct Skipped: Hashable, Sendable {
    public var event: CalendarEvent
    public var reason: SkipReason
}

/// The result of one reconciliation pass: what to do, and why some things were left alone.
public struct Plan: Sendable {
    public var creates: [HoldCreate] = []
    public var updates: [HoldUpdate] = []
    public var deletes: [HoldDelete] = []
    public var skipped: [Skipped] = []
    public var warnings: [String] = []
    public var sourceCount = 0
    public var holdCount = 0

    public init() {}

    public var isEmpty: Bool { creates.isEmpty && updates.isEmpty && deletes.isEmpty }

    public var skippedByReason: [(SkipReason, Int)] {
        Dictionary(grouping: skipped, by: \.reason)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.0.rawValue < $1.0.rawValue }
    }
}

/// Pure reconciliation logic. Given the calendars in the set and every event on them within the
/// window, computes the creates, updates and deletes needed so that each qualifying source event
/// has exactly one hold on every other writable calendar.
public struct Reconciler: Sendable {
    public let settings: SyncSettings

    public init(settings: SyncSettings) {
        self.settings = settings
    }

    private struct HoldKey: Hashable {
        let calendar: CalendarRef
        let identity: HoldMarker.Identity
    }

    /// The title a detailed copy gets: the source title with the source calendar's label in front.
    static func detailedTitle(for source: CalendarEvent, from sourceCalendar: SyncCalendar, fallback: String) -> String {
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = title.isEmpty ? fallback : title
        if let label = sourceCalendar.label?.trimmingCharacters(in: .whitespaces), !label.isEmpty {
            return "[\(label)] \(base)"
        }
        return base
    }

    /// Why a source event does not get holds, or `nil` if it qualifies.
    public func skipReason(for event: CalendarEvent) -> SkipReason? {
        if event.participation == .declined { return .declined }
        if event.status == .canceled { return .canceled }
        if event.availability == .free { return .free }
        if settings.skipAllDay, event.isAllDay { return .allDay }
        if settings.skipTentative,
           event.status == .tentative || event.participation == .tentative || event.availability == .tentative {
            return .tentative
        }
        if settings.skipUnaccepted, event.participation == .pending || event.participation == .unknown {
            return .notAccepted
        }
        if settings.skipTitleKeywords.contains(where: { SyncSettings.titleMatches(event.title, keyword: $0) }) {
            return .keyword
        }
        if event.externalID.isEmpty { return .noIdentifier }
        if event.end <= event.start { return .invalidTimes }
        return nil
    }

    public func plan(calendars: [SyncCalendar], events: [CalendarEvent]) -> Plan {
        var plan = Plan()
        var calendarsByRef: [CalendarRef: SyncCalendar] = [:]
        for calendar in calendars { calendarsByRef[calendar.ref] = calendar }

        // 1. Classify.
        var existing: [HoldKey: [(event: CalendarEvent, marker: HoldMarker)]] = [:]
        var malformed: [CalendarEvent] = []
        var sources: [CalendarEvent] = []
        for event in events {
            switch HoldMarker.classify(event.notes) {
            case .hold(let marker):
                existing[HoldKey(calendar: event.calendar, identity: marker.identity), default: []].append((event, marker))
            case .malformedHold:
                malformed.append(event)
            case .source:
                sources.append(event)
            }
        }
        plan.sourceCount = sources.count
        plan.holdCount = existing.values.reduce(0) { $0 + $1.count } + malformed.count

        // 2. Desired holds.
        var desired: [HoldKey: HoldCreate] = [:]
        var unwritableTargets = Set<CalendarRef>()
        for source in sources.sorted(by: Self.byStart) {
            if let reason = skipReason(for: source) {
                plan.skipped.append(Skipped(event: source, reason: reason))
                continue
            }
            guard let sourceCalendar = calendarsByRef[source.calendar] else {
                plan.warnings.append("event on \(source.calendar) is not in the sync set; ignoring")
                continue
            }
            for target in calendars where target.ref != source.calendar {
                guard target.isWritable else {
                    unwritableTargets.insert(target.ref)
                    continue
                }
                var details: HoldDetails?
                if target.receivesDetails {
                    details = HoldDetails(
                        title: Self.detailedTitle(for: source, from: sourceCalendar, fallback: settings.holdTitle),
                        location: source.location, url: source.url, notes: source.notes)
                }
                let marker = HoldMarker(sourceCalendarKey: sourceCalendar.key,
                                        sourceEventID: source.externalID,
                                        occurrence: source.occurrenceDate,
                                        detailsHash: details?.hash)
                let key = HoldKey(calendar: target.ref, identity: marker.identity)
                if desired[key] == nil {
                    let spec = HoldSpec(title: details?.title ?? settings.holdTitle, start: source.start,
                                        end: source.end, marker: marker, details: details)
                    desired[key] = HoldCreate(target: target, spec: spec, source: source)
                }
            }
        }
        for ref in unwritableTargets.sorted(by: { $0.description < $1.description }) {
            plan.warnings.append("calendar \(ref) is read-only; holds cannot be created on it")
        }

        // 3. Diff desired against existing.
        for (key, create) in desired {
            guard var holds = existing.removeValue(forKey: key) else {
                plan.creates.append(create)
                continue
            }
            holds.sort { $0.event.id < $1.event.id }
            let keep = holds.removeFirst()
            for extra in holds {
                plan.deletes.append(HoldDelete(existing: extra.event, reason: .duplicate))
            }
            var changes: [String] = []
            if abs(keep.event.start.timeIntervalSince(create.spec.start)) > 0.5 { changes.append("start") }
            if abs(keep.event.end.timeIntervalSince(create.spec.end)) > 0.5 { changes.append("end") }
            if keep.event.title != create.spec.title { changes.append("title") }
            if keep.marker.detailsHash != create.spec.marker.detailsHash { changes.append("details") }
            if !changes.isEmpty {
                plan.updates.append(HoldUpdate(existing: keep.event, spec: create.spec, changes: changes))
            }
        }

        // 4. Anything left is a hold with no matching source.
        var unwritableHolds = Set<CalendarRef>()
        for holds in existing.values {
            for (hold, _) in holds {
                if calendarsByRef[hold.calendar]?.isWritable == true {
                    plan.deletes.append(HoldDelete(existing: hold, reason: .orphaned))
                } else {
                    unwritableHolds.insert(hold.calendar)
                }
            }
        }
        for hold in malformed {
            if calendarsByRef[hold.calendar]?.isWritable == true {
                plan.deletes.append(HoldDelete(existing: hold, reason: .malformed))
            } else {
                unwritableHolds.insert(hold.calendar)
            }
        }
        for ref in unwritableHolds.sorted(by: { $0.description < $1.description }) {
            plan.warnings.append("calendar \(ref) is read-only; stale holds on it cannot be removed")
        }

        Self.sort(&plan)
        return plan
    }

    /// A plan that removes every hold on the given calendars.
    public func purgePlan(calendars: [SyncCalendar], events: [CalendarEvent]) -> Plan {
        var plan = Plan()
        var calendarsByRef: [CalendarRef: SyncCalendar] = [:]
        for calendar in calendars { calendarsByRef[calendar.ref] = calendar }
        var unwritable = Set<CalendarRef>()
        for event in events {
            switch HoldMarker.classify(event.notes) {
            case .source:
                plan.sourceCount += 1
            case .hold, .malformedHold:
                plan.holdCount += 1
                if calendarsByRef[event.calendar]?.isWritable == true {
                    plan.deletes.append(HoldDelete(existing: event, reason: .purge))
                } else {
                    unwritable.insert(event.calendar)
                }
            }
        }
        for ref in unwritable.sorted(by: { $0.description < $1.description }) {
            plan.warnings.append("calendar \(ref) is read-only; holds on it cannot be removed")
        }
        Self.sort(&plan)
        return plan
    }

    private static func byStart(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool {
        if a.start != b.start { return a.start < b.start }
        if a.calendar.description != b.calendar.description { return a.calendar.description < b.calendar.description }
        return a.id < b.id
    }

    private static func sort(_ plan: inout Plan) {
        plan.creates.sort {
            if $0.target.ref.description != $1.target.ref.description {
                return $0.target.ref.description < $1.target.ref.description
            }
            return $0.spec.start < $1.spec.start
        }
        plan.updates.sort { byStart($0.existing, $1.existing) }
        plan.deletes.sort { byStart($0.existing, $1.existing) }
        plan.skipped.sort { byStart($0.event, $1.event) }
    }
}
