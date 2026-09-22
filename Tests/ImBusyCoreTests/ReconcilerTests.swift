import XCTest
@testable import ImBusyCore

final class ReconcilerTests: XCTestCase {
    let a = CalendarRef(account: "Account A", calendar: "Work")
    let b = CalendarRef(account: "Account B", calendar: "Calendar")
    let c = CalendarRef(account: "Account C", calendar: "Calendar")

    let now = Date(timeIntervalSince1970: 1_800_000_000) // fixed "now"
    var store: FakeCalendarStore!
    var config: Config!

    override func setUp() {
        store = FakeCalendarStore()
        store.addCalendar(a)
        store.addCalendar(b)
        store.addCalendar(c)
        config = Config(calendars: [
            .init(account: a.account, calendar: a.calendar),
            .init(account: b.account, calendar: b.calendar),
            .init(account: c.account, calendar: c.calendar),
        ])
    }

    func t(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    @discardableResult
    func sync(_ config: Config? = nil) throws -> (Plan, ApplyResult) {
        let config = config ?? self.config!
        let calendars = try SyncRunner.resolveCalendars(config: config, store: store)
        let plan = try SyncRunner.planSync(config: config, calendars: calendars, store: store, now: now)
        let result = try SyncRunner.apply(plan, store: store)
        return (plan, result)
    }

    // MARK: Create

    func testCreatesOneHoldOnEveryOtherCalendar() throws {
        let source = store.addSource(on: a, uid: "uid-1@example.com", start: t(24), end: t(25), title: "Client secret")
        let (plan, result) = try sync()

        XCTAssertEqual(plan.creates.count, 2)
        XCTAssertEqual(result.created, 2)
        XCTAssertEqual(store.holds(on: a).count, 0)
        XCTAssertEqual(store.holds(on: b).count, 1)
        XCTAssertEqual(store.holds(on: c).count, 1)

        let hold = store.holds(on: b)[0]
        XCTAssertEqual(hold.title, "Hold")
        XCTAssertEqual(hold.start, source.start)
        XCTAssertEqual(hold.end, source.end)
        XCTAssertEqual(hold.availability, .busy)
        // Nothing from the source leaks onto the hold.
        XCTAssertFalse(hold.notes!.contains("Client secret"))
        XCTAssertFalse(hold.notes!.contains("Account A"))
        XCTAssertFalse(hold.notes!.contains("Work"))
        let marker = try XCTUnwrap(HoldMarker.parse(hold.notes))
        XCTAssertEqual(marker.sourceEventID, "uid-1@example.com")
        XCTAssertEqual(marker.sourceCalendarKey, HoldMarker.calendarKey(for: a))
        XCTAssertNil(marker.occurrence)
        XCTAssertEqual(store.commits, 1)
    }

    func testUsesConfiguredHoldTitle() throws {
        store.addSource(on: a, uid: "u", start: t(1), end: t(2))
        config.holdTitle = "Busy"
        try sync()
        XCTAssertEqual(store.holds(on: b)[0].title, "Busy")
    }

    // MARK: Idempotency

    func testSecondRunChangesNothing() throws {
        store.addSource(on: a, uid: "u1", start: t(1), end: t(2))
        store.addSource(on: b, uid: "u2", start: t(3), end: t(4))
        try sync()
        let before = store.events
        let (plan, result) = try sync()
        XCTAssertTrue(plan.isEmpty, "second run should be a no-op, got \(plan)")
        XCTAssertEqual(result.created + result.updated + result.deleted, 0)
        XCTAssertEqual(store.events, before)
        XCTAssertEqual(plan.holdCount, 4)
        XCTAssertEqual(plan.sourceCount, 2)
    }

    // MARK: Update

    func testUpdatesHoldsWhenSourceIsRescheduled() throws {
        let source = store.addSource(on: a, uid: "u1", start: t(1), end: t(2))
        try sync()
        store.modify(source) { $0.start = self.t(5); $0.end = self.t(6.5) }

        let (plan, result) = try sync()
        XCTAssertEqual(plan.updates.count, 2)
        XCTAssertEqual(plan.creates.count, 0)
        XCTAssertEqual(plan.deletes.count, 0)
        XCTAssertEqual(result.updated, 2)
        XCTAssertEqual(Set(plan.updates.flatMap(\.changes)), ["start", "end"])
        for ref in [b, c] {
            let holds = store.holds(on: ref)
            XCTAssertEqual(holds.count, 1)
            XCTAssertEqual(holds[0].start, t(5))
            XCTAssertEqual(holds[0].end, t(6.5))
        }
        XCTAssertTrue(try sync().0.isEmpty)
    }

    func testUpdatesTitleWhenHoldTitleChanges() throws {
        store.addSource(on: a, uid: "u1", start: t(1), end: t(2))
        try sync()
        config.holdTitle = "Blocked"
        let (plan, _) = try sync()
        XCTAssertEqual(plan.updates.count, 2)
        XCTAssertEqual(plan.updates[0].changes, ["title"])
        XCTAssertEqual(store.holds(on: b)[0].title, "Blocked")
    }

    // MARK: Delete

    func testDeletesHoldsWhenSourceIsRemoved() throws {
        let source = store.addSource(on: a, uid: "u1", start: t(1), end: t(2))
        try sync()
        store.remove(source)

        let (plan, result) = try sync()
        XCTAssertEqual(plan.deletes.count, 2)
        XCTAssertEqual(plan.deletes[0].reason, .orphaned)
        XCTAssertEqual(result.deleted, 2)
        XCTAssertEqual(store.holds(on: b).count, 0)
        XCTAssertEqual(store.holds(on: c).count, 0)
        XCTAssertTrue(try sync().0.isEmpty)
    }

    func testDeletesHoldsWhenSourceIsCancelledOrDeclined() throws {
        let cancelled = store.addSource(on: a, uid: "u1", start: t(1), end: t(2))
        let declined = store.addSource(on: a, uid: "u2", start: t(3), end: t(4), participation: .accepted)
        try sync()
        XCTAssertEqual(store.holds(on: b).count, 2)

        store.modify(cancelled) { $0.status = .canceled }
        store.modify(declined) { $0.participation = .declined }
        let (plan, _) = try sync()
        XCTAssertEqual(plan.deletes.count, 4)
        XCTAssertEqual(plan.skipped.map(\.reason).sorted { $0.rawValue < $1.rawValue }, [.canceled, .declined])
        XCTAssertEqual(store.holds(on: b).count, 0)
        XCTAssertEqual(store.holds(on: c).count, 0)
    }

    func testDeletesHoldsWhenSourceMovesOutsideWindow() throws {
        let source = store.addSource(on: a, uid: "u1", start: t(1), end: t(2))
        try sync()
        store.modify(source) { $0.start = self.t(24 * 60); $0.end = self.t(24 * 60 + 1) } // 60 days out
        let (plan, _) = try sync()
        XCTAssertEqual(plan.deletes.count, 2)
        XCTAssertEqual(store.holds(on: b).count, 0)
    }

    func testRemovingCalendarFromSetDeletesHoldsDerivedFromIt() throws {
        store.addSource(on: c, uid: "u1", start: t(1), end: t(2))
        try sync()
        XCTAssertEqual(store.holds(on: a).count, 1)

        config.calendars.removeLast() // drop C
        let (plan, _) = try sync()
        XCTAssertEqual(plan.deletes.count, 2)
        XCTAssertEqual(store.holds(on: a).count, 0)
        XCTAssertEqual(store.holds(on: b).count, 0)
    }

    // MARK: No hold-of-hold

    func testHoldsNeverSpawnHolds() throws {
        store.addSource(on: a, uid: "u1", start: t(1), end: t(2))
        try sync()
        try sync()
        try sync()
        XCTAssertEqual(store.holds(on: a).count, 0, "holds on B and C must not produce a hold back on A")
        XCTAssertEqual(store.holds(on: b).count, 1)
        XCTAssertEqual(store.holds(on: c).count, 1)
        XCTAssertEqual(store.events.count, 3)
    }

    func testHoldWithMangledMarkerIsDeletedNotTreatedAsSource() throws {
        // The prefix survived but the rest was rewritten by a server.
        store.addRaw(on: b, uid: "x", start: t(1), end: t(2), title: "Hold", notes: "imbusy:v1 src=??? garbage")
        let (plan, _) = try sync()
        XCTAssertEqual(plan.creates.count, 0)
        XCTAssertEqual(plan.deletes.count, 1)
        XCTAssertEqual(plan.deletes[0].reason, .malformed)
        XCTAssertEqual(store.events.count, 0)
    }

    func testDuplicateHoldsAreCollapsedToOne() throws {
        let source = store.addSource(on: a, uid: "u1", start: t(1), end: t(2))
        try sync()
        // Simulate a duplicated hold (e.g. a sync glitch copying the event).
        let existing = store.holds(on: b)[0]
        store.addRaw(on: b, uid: "dup", start: source.start, end: source.end, title: "Hold", notes: existing.notes)
        XCTAssertEqual(store.holds(on: b).count, 2)

        let (plan, _) = try sync()
        XCTAssertEqual(plan.deletes.count, 1)
        XCTAssertEqual(plan.deletes[0].reason, .duplicate)
        XCTAssertEqual(store.holds(on: b).count, 1)
        XCTAssertTrue(try sync().0.isEmpty)
    }

    // MARK: Recurring

    func testEachRecurringOccurrenceGetsItsOwnHold() throws {
        let uid = "recurring@example.com"
        var occurrences: [CalendarEvent] = []
        for day in 0..<3 {
            occurrences.append(store.addSource(on: a, uid: uid, start: t(Double(24 * day) + 9), end: t(Double(24 * day) + 10),
                                               occurrence: t(Double(24 * day) + 9)))
        }
        let (plan, _) = try sync()
        XCTAssertEqual(plan.creates.count, 6)
        XCTAssertEqual(store.holds(on: b).count, 3)
        let markers = store.holds(on: b).map { HoldMarker.parse($0.notes)! }
        XCTAssertEqual(Set(markers).count, 3)
        XCTAssertEqual(Set(markers.map(\.sourceEventID)), [uid])
        XCTAssertEqual(markers.compactMap(\.occurrence).sorted(), occurrences.map(\.start))
        XCTAssertTrue(try sync().0.isEmpty)

        // Move one occurrence (a detached occurrence keeps its original occurrenceDate).
        store.modify(occurrences[1]) { $0.start = self.t(24 + 14); $0.end = self.t(24 + 15) }
        let (plan2, _) = try sync()
        XCTAssertEqual(plan2.updates.count, 2)
        XCTAssertEqual(plan2.creates.count, 0)
        XCTAssertEqual(plan2.deletes.count, 0)
        XCTAssertEqual(store.holds(on: c).map(\.start).sorted(), [t(9), t(24 + 14), t(48 + 9)])

        // Delete one occurrence.
        store.remove(occurrences[2])
        let (plan3, _) = try sync()
        XCTAssertEqual(plan3.deletes.count, 2)
        XCTAssertEqual(store.holds(on: b).count, 2)
        XCTAssertTrue(try sync().0.isEmpty)
    }

    // MARK: Skip rules

    func testSkipRules() throws {
        store.addSource(on: a, uid: "declined", start: t(1), end: t(2), participation: .declined)
        store.addSource(on: a, uid: "free", start: t(1), end: t(2), availability: .free)
        store.addSource(on: a, uid: "canceled", start: t(1), end: t(2), status: .canceled)
        store.addSource(on: a, uid: "allday", start: t(0), end: t(24), isAllDay: true)
        store.addSource(on: a, uid: "tentative-status", start: t(1), end: t(2), status: .tentative)
        store.addSource(on: a, uid: "tentative-me", start: t(1), end: t(2), participation: .tentative)
        store.addSource(on: a, uid: "", start: t(1), end: t(2))
        store.addSource(on: a, uid: "zero", start: t(1), end: t(1))
        store.addSource(on: a, uid: "ok-accepted", start: t(1), end: t(2), participation: .accepted)
        store.addSource(on: a, uid: "ok-pending", start: t(1), end: t(2), participation: .pending)
        store.addSource(on: a, uid: "ok-unsupported", start: t(1), end: t(2), availability: .notSupported)

        // Defaults: skip all-day, keep tentative.
        let (plan, _) = try sync()
        let skipped = Dictionary(uniqueKeysWithValues: plan.skipped.map { ($0.event.externalID, $0.reason) })
        XCTAssertEqual(skipped, ["declined": .declined, "free": .free, "canceled": .canceled,
                                 "allday": .allDay, "": .noIdentifier, "zero": .invalidTimes])
        XCTAssertEqual(store.holds(on: b).count, 5)
        XCTAssertEqual(plan.skippedByReason.map(\.1).reduce(0, +), 6)

        // skipTentative on, skipAllDay off.
        config.skipTentative = true
        config.skipAllDay = false
        let (plan2, _) = try sync()
        XCTAssertEqual(Set(plan2.skipped.map(\.reason)), [.declined, .free, .canceled, .tentative, .noIdentifier, .invalidTimes])
        XCTAssertEqual(plan2.skipped.filter { $0.reason == .tentative }.count, 2)
        XCTAssertEqual(store.holds(on: b).count, 4) // +allday, -2 tentative
        XCTAssertTrue(store.holds(on: b).contains { $0.end.timeIntervalSince($0.start) == 86_400 })
    }

    func testSkipTitleKeywordsMatchWholeWordsCaseInsensitively() throws {
        store.addSource(on: a, uid: "plain", start: t(1), end: t(2), title: "Hold")
        store.addSource(on: a, uid: "upper", start: t(1), end: t(2), title: "HOLD: travel")
        store.addSource(on: a, uid: "dash", start: t(1), end: t(2), title: "Hold - Acme")
        store.addSource(on: a, uid: "parens", start: t(1), end: t(2), title: "Standup (hold)")
        store.addSource(on: a, uid: "substring", start: t(1), end: t(2), title: "Stakeholder sync")
        store.addSource(on: a, uid: "holdings", start: t(1), end: t(2), title: "Holdings review")
        store.addSource(on: a, uid: "phrase", start: t(1), end: t(2), title: "Do not book: dentist")

        // Default: nothing skipped by keyword.
        let (plan, _) = try sync()
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertEqual(store.holds(on: b).count, 7)

        config.skipTitleKeywords = ["Hold", "do not book"]
        let (plan2, _) = try sync()
        let skipped = Set(plan2.skipped.map(\.event.externalID))
        XCTAssertEqual(skipped, ["plain", "upper", "dash", "parens", "phrase"])
        XCTAssertTrue(plan2.skipped.allSatisfy { $0.reason == .keyword })
        XCTAssertEqual(plan2.deletes.count, 10, "holds for the now-ignored events are removed on both targets")
        XCTAssertEqual(store.holds(on: b).count, 2)
        XCTAssertTrue(try sync().0.isEmpty)
    }

    func testSkipUnacceptedIgnoresInvitationsWithoutAResponse() throws {
        store.addSource(on: a, uid: "pending", start: t(1), end: t(2), participation: .pending)
        store.addSource(on: a, uid: "unknown", start: t(1), end: t(2), participation: .unknown)
        store.addSource(on: a, uid: "accepted", start: t(1), end: t(2), participation: .accepted)
        store.addSource(on: a, uid: "tentative", start: t(1), end: t(2), participation: .tentative)
        store.addSource(on: a, uid: "mine", start: t(1), end: t(2), participation: .notAnAttendee)

        // Off by default: pending invitations still get holds.
        let (plan, _) = try sync()
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertEqual(store.holds(on: b).count, 5)

        config.skipUnaccepted = true
        let (plan2, _) = try sync()
        XCTAssertEqual(Set(plan2.skipped.map(\.event.externalID)), ["pending", "unknown"])
        XCTAssertTrue(plan2.skipped.allSatisfy { $0.reason == .notAccepted })
        XCTAssertEqual(plan2.deletes.count, 4, "existing holds for unaccepted invitations are removed")
        XCTAssertEqual(store.holds(on: b).count, 3)
        XCTAssertTrue(try sync().0.isEmpty)

        // Accepting the invitation brings the holds back.
        store.modify(store.sources(on: a).first { $0.externalID == "pending" }!) { $0.participation = .accepted }
        let (plan3, _) = try sync()
        XCTAssertEqual(plan3.creates.count, 2)
        XCTAssertEqual(store.holds(on: b).count, 4)
    }

    func testSkipTitleKeywordsNeverAffectMarkedHolds() throws {
        // Our own holds carry the marker and are classified before any title rule applies.
        store.addSource(on: a, uid: "u1", start: t(1), end: t(2))
        config.skipTitleKeywords = ["Hold"]
        try sync()
        XCTAssertEqual(store.holds(on: b).count, 1)
        XCTAssertTrue(try sync().0.isEmpty)
    }

    // MARK: Detailed copies

    func testDetailedCalendarReceivesCopiesAndOthersGetBareHolds() throws {
        let store = FakeCalendarStore()
        store.addCalendar(a, receivesDetails: true)
        store.addCalendar(b, label: "B-Client")
        store.addCalendar(c)
        self.store = store
        let source = store.addSource(on: b, uid: "u1", start: t(1), end: t(2), title: "Design review",
                                     location: "Room 4", url: "https://meet.example/abc",
                                     notes: "Agenda: everything\nJoin: https://meet.example/abc")
        store.addSource(on: c, uid: "u2", start: t(3), end: t(4), title: "Unlabelled calendar event")

        let (plan, _) = try sync()
        XCTAssertEqual(plan.creates.count, 4)

        let copies = store.holds(on: a)
        XCTAssertEqual(copies.count, 2)
        let copy = copies[0]
        XCTAssertEqual(copy.title, "[B-Client] Design review")
        XCTAssertEqual(copy.location, "Room 4")
        XCTAssertEqual(copy.url, "https://meet.example/abc")
        XCTAssertTrue(copy.notes!.hasPrefix("Agenda: everything"))
        XCTAssertTrue(copy.notes!.contains("Join: https://meet.example/abc"))
        let marker = try XCTUnwrap(HoldMarker.parse(copy.notes))
        XCTAssertNotNil(marker.detailsHash)
        XCTAssertEqual(marker.sourceEventID, source.externalID)
        XCTAssertEqual(copies[1].title, "Unlabelled calendar event", "no label means no prefix")

        // Bare holds elsewhere: nothing copied.
        for hold in store.holds(on: c) + store.holds(on: b) {
            XCTAssertEqual(hold.title, "Hold")
            XCTAssertNil(hold.location)
            XCTAssertNil(hold.url)
            XCTAssertFalse(hold.notes!.contains("Agenda"))
            XCTAssertFalse(hold.notes!.contains("Design review"))
            XCTAssertNil(HoldMarker.parse(hold.notes)!.detailsHash)
        }
        XCTAssertTrue(try sync().0.isEmpty, "second run must be a no-op")
    }

    func testDetailChangeUpdatesOnlyTheDetailedCopy() throws {
        let store = FakeCalendarStore()
        store.addCalendar(a, receivesDetails: true)
        store.addCalendar(b, label: "B")
        store.addCalendar(c)
        self.store = store
        let source = store.addSource(on: b, uid: "u1", start: t(1), end: t(2), title: "Standup", notes: "old link")
        try sync()

        store.modify(source) { $0.notes = "new link"; $0.location = "Zoom" }
        let (plan, _) = try sync()
        XCTAssertEqual(plan.updates.count, 1)
        XCTAssertEqual(plan.updates[0].existing.calendar, a)
        XCTAssertEqual(plan.updates[0].changes, ["details"])
        XCTAssertEqual(plan.creates.count + plan.deletes.count, 0)
        let copy = store.holds(on: a)[0]
        XCTAssertEqual(copy.location, "Zoom")
        XCTAssertTrue(copy.notes!.hasPrefix("new link"))
        XCTAssertTrue(try sync().0.isEmpty)

        // Renaming the source changes the title and the hash.
        store.modify(source) { $0.title = "Daily standup" }
        let (plan2, _) = try sync()
        XCTAssertEqual(plan2.updates.count, 1)
        XCTAssertEqual(plan2.updates[0].changes, ["title", "details"])
        XCTAssertEqual(store.holds(on: a)[0].title, "[B] Daily standup")
    }

    func testEnablingDetailsUpgradesExistingBareHoldsInPlace() throws {
        let store = FakeCalendarStore()
        var primary = store.addCalendar(a)
        store.addCalendar(b, label: "B")
        self.store = store
        config.calendars.removeLast()
        store.addSource(on: b, uid: "u1", start: t(1), end: t(2), title: "Kickoff", notes: "details")
        try sync()
        XCTAssertEqual(store.holds(on: a)[0].title, "Hold")
        let bareID = store.holds(on: a)[0].id

        primary = store.addCalendar(a, receivesDetails: true)
        XCTAssertTrue(primary.receivesDetails)
        let (plan, _) = try sync()
        XCTAssertEqual(plan.updates.count, 1)
        XCTAssertEqual(plan.updates[0].changes, ["title", "details"])
        XCTAssertEqual(plan.creates.count + plan.deletes.count, 0, "upgrade in place, not delete and recreate")
        XCTAssertEqual(store.holds(on: a)[0].id, bareID)
        XCTAssertEqual(store.holds(on: a)[0].title, "[B] Kickoff")

        // And back again when the flag is turned off.
        store.addCalendar(a, receivesDetails: false)
        let (plan2, _) = try sync()
        XCTAssertEqual(plan2.updates.count, 1)
        let hold = store.holds(on: a)[0]
        XCTAssertEqual(hold.title, "Hold")
        XCTAssertNil(hold.location)
        XCTAssertFalse(hold.notes!.contains("details"))
        XCTAssertNil(HoldMarker.parse(hold.notes)!.detailsHash)
    }

    // MARK: Read-only calendars

    func testReadOnlyCalendarIsSourceButNotTarget() throws {
        let store = FakeCalendarStore()
        store.addCalendar(a)
        store.addCalendar(b, writable: false)
        self.store = store
        config.calendars.removeLast() // A + B only
        store.addSource(on: b, uid: "on-readonly", start: t(1), end: t(2))
        store.addSource(on: a, uid: "on-a", start: t(3), end: t(4))

        let (plan, result) = try sync()
        XCTAssertEqual(plan.creates.count, 1)
        XCTAssertEqual(plan.creates[0].target.ref, a)
        XCTAssertEqual(result.created, 1)
        XCTAssertEqual(store.holds(on: b).count, 0)
        XCTAssertEqual(store.holds(on: a).count, 1)
        XCTAssertTrue(plan.warnings.contains { $0.contains("read-only") }, "expected a read-only warning")
    }

    // MARK: Purge

    func testPurgeRemovesAllHoldsAndOnlyHolds() throws {
        store.addSource(on: a, uid: "u1", start: t(1), end: t(2))
        store.addSource(on: b, uid: "u2", start: t(3), end: t(4))
        try sync()
        XCTAssertEqual(store.events.count, 6)

        let calendars = try SyncRunner.resolveCalendars(config: config, store: store)
        let plan = try SyncRunner.planPurge(config: config, calendars: calendars, store: store,
                                            window: DateInterval(start: t(-24), end: t(24 * 365)))
        XCTAssertEqual(plan.deletes.count, 4)
        XCTAssertTrue(plan.deletes.allSatisfy { $0.reason == .purge })
        let result = try SyncRunner.apply(plan, store: store)
        XCTAssertEqual(result.deleted, 4)
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.sources(on: a).count, 1)
        XCTAssertEqual(store.sources(on: b).count, 1)
    }

    // MARK: Apply robustness

    func testApplyContinuesPastFailures() throws {
        store.addSource(on: a, uid: "u1", start: t(1), end: t(2))
        let calendars = try SyncRunner.resolveCalendars(config: config, store: store)
        var plan = try SyncRunner.planSync(config: config, calendars: calendars, store: store, now: now)
        // A delete for an event that no longer exists must not stop the creates.
        let ghost = CalendarEvent(id: "ghost", calendar: b, externalID: "g", start: t(1), end: t(2), title: "Hold")
        plan.deletes.append(HoldDelete(existing: ghost, reason: .orphaned))
        let result = try SyncRunner.apply(plan, store: store)
        XCTAssertEqual(result.created, 2)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(store.commits, 1)
    }
}
