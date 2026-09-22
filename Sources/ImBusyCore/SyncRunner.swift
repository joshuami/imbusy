import Foundation

/// Outcome of applying a plan.
public struct ApplyResult: Sendable {
    public var created = 0
    public var updated = 0
    public var deleted = 0
    public var failures: [String] = []

    public init() {}
}

/// Glue between config, a `CalendarStore`, and the `Reconciler`.
public enum SyncRunner {
    public static func resolveCalendars(config: Config, store: CalendarStore) throws -> [SyncCalendar] {
        try config.calendars.map { try store.resolve($0) }
    }

    public static func window(now: Date, lookaheadDays: Int) -> DateInterval {
        DateInterval(start: now, end: now.addingTimeInterval(TimeInterval(lookaheadDays) * 86_400))
    }

    public static func fetchEvents(calendars: [SyncCalendar], window: DateInterval,
                                   store: CalendarStore) throws -> [CalendarEvent] {
        try calendars.flatMap { try store.events(in: $0, from: window.start, to: window.end) }
    }

    /// Compute the sync plan for `config` as of `now`.
    public static func planSync(config: Config, calendars: [SyncCalendar], store: CalendarStore,
                                now: Date = Date()) throws -> Plan {
        let window = window(now: now, lookaheadDays: config.lookaheadDays)
        let events = try fetchEvents(calendars: calendars, window: window, store: store)
        return Reconciler(settings: SyncSettings(config: config)).plan(calendars: calendars, events: events)
    }

    /// Compute a purge plan over an explicit window.
    public static func planPurge(config: Config, calendars: [SyncCalendar], store: CalendarStore,
                                 window: DateInterval) throws -> Plan {
        let events = try fetchEvents(calendars: calendars, window: window, store: store)
        return Reconciler(settings: SyncSettings(config: config)).purgePlan(calendars: calendars, events: events)
    }

    /// Apply every action in `plan`, continuing past individual failures, then commit.
    public static func apply(_ plan: Plan, store: CalendarStore) throws -> ApplyResult {
        var result = ApplyResult()
        for create in plan.creates {
            do {
                try store.createHold(create.spec, in: create.target)
                result.created += 1
            } catch {
                result.failures.append("create on \(create.target.ref): \(error)")
            }
        }
        for update in plan.updates {
            do {
                try store.updateHold(update.existing, to: update.spec)
                result.updated += 1
            } catch {
                result.failures.append("update on \(update.existing.calendar): \(error)")
            }
        }
        for delete in plan.deletes {
            do {
                try store.deleteHold(delete.existing)
                result.deleted += 1
            } catch {
                result.failures.append("delete on \(delete.existing.calendar): \(error)")
            }
        }
        try store.commit()
        return result
    }
}
