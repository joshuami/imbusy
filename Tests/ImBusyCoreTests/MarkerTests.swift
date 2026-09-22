import XCTest
@testable import ImBusyCore

final class MarkerTests: XCTestCase {
    let ref = CalendarRef(account: "Some Account", calendar: "Some Calendar")

    func testRoundTrip() throws {
        let occurrence = Date(timeIntervalSince1970: 1_800_000_123.7)
        let marker = HoldMarker(sourceCalendarKey: HoldMarker.calendarKey(for: ref),
                                sourceEventID: "040000008200E00074C5B7101A82E008 weird/chars+here@example.com",
                                occurrence: occurrence)
        let parsed = try XCTUnwrap(HoldMarker.parse(marker.notesText))
        XCTAssertEqual(parsed, marker)
        XCTAssertEqual(parsed.occurrence, Date(timeIntervalSince1970: 1_800_000_123))
        XCTAssertFalse(marker.line.contains(" weird"), "identifier must be percent-encoded: \(marker.line)")
    }

    func testRoundTripWithoutOccurrence() throws {
        let marker = HoldMarker(sourceCalendarKey: "abc", sourceEventID: "uid@google.com", occurrence: nil)
        XCTAssertTrue(marker.line.hasSuffix("occ=-"))
        XCTAssertEqual(HoldMarker.parse(marker.line), marker)
    }

    func testSurvivesServerRewrites() throws {
        let marker = HoldMarker(sourceCalendarKey: "abc123", sourceEventID: "uid-1", occurrence: Date(timeIntervalSince1970: 0))
        // Exchange may wrap notes in HTML, change line breaks, or add whitespace.
        let html = "<html><body><p>Created automatically by imbusy.</p><p>\(marker.line)</p></body></html>"
        XCTAssertEqual(HoldMarker.parse(html), marker)
        let crlf = "Created automatically\r\n  \(marker.line)\r\n"
        XCTAssertEqual(HoldMarker.parse(crlf), marker)
        let userEdited = "my own note above\n\n\(marker.line)\n\nand below"
        XCTAssertEqual(HoldMarker.parse(userEdited), marker)
    }

    func testDetailsHashRoundTripAndIdentity() throws {
        let with = HoldMarker(sourceCalendarKey: "abc", sourceEventID: "u", occurrence: nil,
                              detailsHash: HoldMarker.shortHash("some details"))
        let without = HoldMarker(sourceCalendarKey: "abc", sourceEventID: "u", occurrence: nil)
        XCTAssertTrue(with.line.contains(" det="))
        XCTAssertFalse(without.line.contains("det="))
        XCTAssertEqual(HoldMarker.parse(with.detailedNotesText), with)
        XCTAssertEqual(HoldMarker.parse("Agenda\n\n" + with.detailedNotesText), with)
        XCTAssertEqual(HoldMarker.parse(without.notesText), without)
        XCTAssertNotEqual(with, without)
        XCTAssertEqual(with.identity, without.identity, "identity ignores the details hash")
        XCTAssertEqual(HoldMarker.parse("<p>\(with.line)</p>"), with)
    }

    func testClassification() {
        let marker = HoldMarker(sourceCalendarKey: "abc", sourceEventID: "u", occurrence: nil)
        XCTAssertEqual(HoldMarker.classify(nil), .source)
        XCTAssertEqual(HoldMarker.classify("Agenda: discuss things"), .source)
        XCTAssertEqual(HoldMarker.classify(marker.notesText), .hold(marker))
        XCTAssertEqual(HoldMarker.classify("imbusy:v1 src=abc evt=u"), .malformedHold)
        XCTAssertEqual(HoldMarker.classify("imbusy:v1 src=abc evt=u occ=notadate"), .malformedHold)
    }

    func testCalendarKeyIsStableAndOpaque() {
        let key = HoldMarker.calendarKey(for: ref)
        XCTAssertEqual(key, HoldMarker.calendarKey(for: ref))
        XCTAssertEqual(key.count, 16)
        XCTAssertFalse(key.contains("Some"))
        XCTAssertNotEqual(key, HoldMarker.calendarKey(for: CalendarRef(account: "Some Account", calendar: "Other")))
        XCTAssertNotEqual(key, HoldMarker.calendarKey(for: CalendarRef(account: "Some", calendar: "Account Some Calendar")))
    }

    func testDateTokenFormat() {
        let date = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z
        XCTAssertEqual(HoldMarker.format(date), "20270115T080000Z")
        XCTAssertEqual(HoldMarker.parseDate("20270115T080000Z"), date)
        XCTAssertNil(HoldMarker.parseDate("2027-01-15T08:00:00Z"))
        XCTAssertNil(HoldMarker.parseDate("20271315T080000Z"))
    }
}
