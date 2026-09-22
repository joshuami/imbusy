import CryptoKit
import Foundation

/// The marker that identifies a hold as ours and names its source occurrence.
///
/// Rendered as a single line, for example:
///
///     imbusy:v1 src=3f9a1c0b7d2e4a68 evt=abc123%40google.com occ=20260923T100000Z det=9c1d2e3f4a5b6c7d
///
/// - `src`: opaque key of the source calendar (hash of account + calendar name)
/// - `evt`: percent-encoded server-side identifier (iCalendar UID) of the source event
/// - `occ`: original start of the occurrence for recurring events, `-` for single events
/// - `det`: optional hash of the copied details, only on calendars that receive details
///
/// It is stored in the hold's notes. See README "Marker field" for why notes was chosen.
public struct HoldMarker: Hashable, Sendable, CustomStringConvertible {
    public static let prefix = "imbusy:v1"

    public var sourceCalendarKey: String
    public var sourceEventID: String
    public var occurrence: Date?
    public var detailsHash: String?

    public init(sourceCalendarKey: String, sourceEventID: String, occurrence: Date?, detailsHash: String? = nil) {
        self.sourceCalendarKey = sourceCalendarKey
        self.sourceEventID = sourceEventID
        // Whole-second precision so that the value survives a text round trip unchanged.
        self.occurrence = occurrence.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        self.detailsHash = detailsHash
    }

    /// The part of the marker that identifies the source occurrence, ignoring the details hash.
    public struct Identity: Hashable, Sendable {
        public var sourceCalendarKey: String
        public var sourceEventID: String
        public var occurrence: Date?
    }

    public var identity: Identity {
        Identity(sourceCalendarKey: sourceCalendarKey, sourceEventID: sourceEventID, occurrence: occurrence)
    }

    /// First 16 hex characters of the SHA-256 of `text`.
    public static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Calendar key

    /// Deterministic, opaque key for a calendar. Derived from the configured names so it is stable
    /// across machines and reinstalls, and reveals nothing about the account it points at.
    public static func calendarKey(for ref: CalendarRef) -> String {
        shortHash("\(ref.account)\u{1F}\(ref.calendar)")
    }

    // MARK: Rendering

    private static let idAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.@")
        return set
    }()

    public var line: String {
        let evt = sourceEventID.addingPercentEncoding(withAllowedCharacters: Self.idAllowed) ?? sourceEventID
        let occ = occurrence.map(Self.format) ?? "-"
        var line = "\(Self.prefix) src=\(sourceCalendarKey) evt=\(evt) occ=\(occ)"
        if let detailsHash { line += " det=\(detailsHash)" }
        return line
    }

    public var description: String { line }

    public var notesText: String {
        "Created automatically by imbusy to hold time that is booked on another calendar. "
            + "Do not edit; changes will be overwritten.\n\(line)"
    }

    /// Trailer for detailed copies, placed after the copied source notes.
    public var detailedNotesText: String {
        "Copied automatically by imbusy from an event on another calendar. Edits here are overwritten; "
            + "reply to or edit the original instead.\n\(line)"
    }

    // MARK: Parsing

    public enum Classification: Hashable, Sendable {
        /// No marker present: a real event created by a person or another system.
        case source
        /// One of our holds with an intact marker.
        case hold(HoldMarker)
        /// Carries our prefix but the marker could not be parsed (for example mangled by a server).
        case malformedHold
    }

    public static func classify(_ notes: String?) -> Classification {
        guard let notes, notes.contains(prefix) else { return .source }
        return parse(notes).map { .hold($0) } ?? .malformedHold
    }

    private static let regex = try! NSRegularExpression(
        pattern: #"imbusy:v1\s+src=([A-Za-z0-9]+)\s+evt=(\S+?)\s+occ=([0-9]{8}T[0-9]{6}Z|-)(?:\s+det=([a-f0-9]{16}))?"#
    )

    public static func parse(_ text: String?) -> HoldMarker? {
        guard let text else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let srcRange = Range(match.range(at: 1), in: text),
              let evtRange = Range(match.range(at: 2), in: text),
              let occRange = Range(match.range(at: 3), in: text)
        else { return nil }
        let src = String(text[srcRange])
        guard let evt = String(text[evtRange]).removingPercentEncoding, !evt.isEmpty else { return nil }
        let occText = String(text[occRange])
        var occurrence: Date?
        if occText != "-" {
            guard let date = parseDate(occText) else { return nil }
            occurrence = date
        }
        var detailsHash: String?
        if let detRange = Range(match.range(at: 4), in: text) {
            detailsHash = String(text[detRange])
        }
        return HoldMarker(sourceCalendarKey: src, sourceEventID: evt, occurrence: occurrence, detailsHash: detailsHash)
    }

    // MARK: Date tokens (yyyyMMddTHHmmssZ, always UTC)

    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    static func format(_ date: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ",
                      c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    static func parseDate(_ token: String) -> Date? {
        guard token.count == 16, token[token.index(token.startIndex, offsetBy: 8)] == "T", token.hasSuffix("Z") else {
            return nil
        }
        let digits = Array(token)
        func int(_ from: Int, _ len: Int) -> Int? { Int(String(digits[from..<(from + len)])) }
        guard let y = int(0, 4), let mo = int(4, 2), let d = int(6, 2),
              let h = int(9, 2), let mi = int(11, 2), let s = int(13, 2) else { return nil }
        guard (1...12).contains(mo), (1...31).contains(d), (0...23).contains(h),
              (0...59).contains(mi), (0...59).contains(s) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = mi; comps.second = s
        guard let date = utcCalendar.date(from: comps), format(date) == token else { return nil }
        return date
    }
}
