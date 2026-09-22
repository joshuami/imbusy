import XCTest
@testable import ImBusyCore

final class ConfigTests: XCTestCase {
    func testDefaultsApplyForMissingKeys() throws {
        let json = """
        { "calendars": [ { "account": "A", "calendar": "X" }, { "account": "B", "calendar": "Y" } ] }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.holdTitle, "Hold")
        XCTAssertEqual(config.lookaheadDays, 30)
        XCTAssertTrue(config.skipAllDay)
        XCTAssertFalse(config.skipTentative)
        XCTAssertFalse(config.skipUnaccepted)
        XCTAssertEqual(config.skipTitleKeywords, [])
        XCTAssertFalse(config.mergeOverlappingHolds)
        XCTAssertNil(config.calendars[0].calendarIdentifier)
        XCTAssertNoThrow(try config.validate())
    }

    func testExplicitValues() throws {
        let json = """
        {
          "calendars": [
            { "account": "A", "calendar": "X", "calendarIdentifier": "ABC-123", "receivesDetails": true },
            { "account": "B", "calendar": "Y", "label": "Bee" }
          ],
          "holdTitle": "Busy",
          "lookaheadDays": 14,
          "skipAllDay": false,
          "skipTentative": true,
          "skipUnaccepted": true,
          "skipTitleKeywords": ["Hold", "Do not book"],
          "mergeOverlappingHolds": true
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.holdTitle, "Busy")
        XCTAssertEqual(config.lookaheadDays, 14)
        XCTAssertFalse(config.skipAllDay)
        XCTAssertTrue(config.skipTentative)
        XCTAssertTrue(config.skipUnaccepted)
        XCTAssertEqual(config.skipTitleKeywords, ["Hold", "Do not book"])
        XCTAssertTrue(config.mergeOverlappingHolds)
        XCTAssertEqual(config.calendars[0].calendarIdentifier, "ABC-123")
        XCTAssertEqual(config.calendars[0].receivesDetails, true)
        XCTAssertNil(config.calendars[0].label)
        XCTAssertEqual(config.calendars[1].label, "Bee")
        XCTAssertNil(config.calendars[1].receivesDetails)
    }

    func testValidation() {
        let one = Config(calendars: [.init(account: "A", calendar: "X")])
        XCTAssertThrowsError(try one.validate())

        let duplicate = Config(calendars: [.init(account: "A", calendar: "X"), .init(account: "A", calendar: "X")])
        XCTAssertThrowsError(try duplicate.validate())

        var bad = Config(calendars: [.init(account: "A", calendar: "X"), .init(account: "B", calendar: "Y")])
        bad.holdTitle = "  "
        XCTAssertThrowsError(try bad.validate())
        bad.holdTitle = "Hold"
        bad.lookaheadDays = 0
        XCTAssertThrowsError(try bad.validate())
        bad.lookaheadDays = 5000
        XCTAssertThrowsError(try bad.validate())
        bad.lookaheadDays = 30
        XCTAssertNoThrow(try bad.validate())
        bad.skipTitleKeywords = ["Hold", " "]
        XCTAssertThrowsError(try bad.validate())
    }

    func testExampleConfigInRepoIsValid() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config.example.json")
        let config = try Config.load(from: url)
        XCTAssertGreaterThanOrEqual(config.calendars.count, 2)
    }

    func testLoadMissingFile() {
        XCTAssertThrowsError(try Config.load(from: URL(fileURLWithPath: "/nonexistent/config.json"))) { error in
            XCTAssertTrue("\(error)".contains("not found"))
        }
    }
}
