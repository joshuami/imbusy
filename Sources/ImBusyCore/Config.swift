import Foundation

/// User configuration, loaded from `~/.config/imbusy/config.json` by default.
public struct Config: Equatable, Sendable {
    public struct CalendarEntry: Codable, Equatable, Sendable {
        /// Account name as shown by `list-calendars` (the EventKit source title).
        public var account: String
        /// Calendar name as shown by `list-calendars`.
        public var calendar: String
        /// Optional. Use the identifier printed by `list-calendars` when two calendars share
        /// the same account and calendar name.
        public var calendarIdentifier: String?
        /// Optional short label, prefixed to titles copied from this calendar onto a calendar
        /// that receives details, e.g. "Acme" gives "[Acme] Design check-in".
        public var label: String?
        /// Optional. When true, holds on this calendar carry the source event's title, location,
        /// URL and notes instead of the bare hold title. Off by default.
        public var receivesDetails: Bool?

        public init(account: String, calendar: String, calendarIdentifier: String? = nil,
                    label: String? = nil, receivesDetails: Bool? = nil) {
            self.account = account
            self.calendar = calendar
            self.calendarIdentifier = calendarIdentifier
            self.label = label
            self.receivesDetails = receivesDetails
        }

        public var ref: CalendarRef { CalendarRef(account: account, calendar: calendar) }
    }

    public var calendars: [CalendarEntry]
    public var holdTitle: String
    public var lookaheadDays: Int
    public var skipAllDay: Bool
    public var skipTentative: Bool
    /// Ignore invitations you have not responded to yet.
    public var skipUnaccepted: Bool
    /// Source events whose title contains any of these words (whole word, case-insensitive) are
    /// ignored. Useful for holds you created by hand before adopting imbusy.
    public var skipTitleKeywords: [String]
    public var mergeOverlappingHolds: Bool

    public static let defaultHoldTitle = "Hold"
    public static let defaultLookaheadDays = 30
    /// EventKit refuses date-range predicates longer than four years.
    public static let maxLookaheadDays = 4 * 365

    public init(calendars: [CalendarEntry], holdTitle: String = Config.defaultHoldTitle,
                lookaheadDays: Int = Config.defaultLookaheadDays, skipAllDay: Bool = true,
                skipTentative: Bool = false, skipUnaccepted: Bool = false, skipTitleKeywords: [String] = [],
                mergeOverlappingHolds: Bool = false) {
        self.calendars = calendars
        self.holdTitle = holdTitle
        self.lookaheadDays = lookaheadDays
        self.skipAllDay = skipAllDay
        self.skipTentative = skipTentative
        self.skipUnaccepted = skipUnaccepted
        self.skipTitleKeywords = skipTitleKeywords
        self.mergeOverlappingHolds = mergeOverlappingHolds
    }

    // MARK: Loading

    /// `$XDG_CONFIG_HOME/imbusy/config.json`, falling back to `~/.config/imbusy/config.json`.
    public static var defaultURL: URL {
        let env = ProcessInfo.processInfo.environment
        let base: URL
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("imbusy", isDirectory: true).appendingPathComponent("config.json")
    }

    public static func load(from url: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigError.fileNotFound(url)
        }
        let data = try Data(contentsOf: url)
        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw ConfigError.invalidJSON(url, error)
        }
        try config.validate()
        return config
    }

    public func validate() throws {
        guard calendars.count >= 2 else {
            throw ConfigError.invalid("\"calendars\" must list at least two calendars to sync between")
        }
        var seen = Set<CalendarRef>()
        for entry in calendars {
            let trimmedAccount = entry.account.trimmingCharacters(in: .whitespaces)
            let trimmedCalendar = entry.calendar.trimmingCharacters(in: .whitespaces)
            guard !trimmedAccount.isEmpty, !trimmedCalendar.isEmpty else {
                throw ConfigError.invalid("every calendar entry needs a non-empty \"account\" and \"calendar\"")
            }
            guard seen.insert(entry.ref).inserted else {
                throw ConfigError.invalid("calendar \"\(entry.ref)\" is listed more than once")
            }
        }
        guard !holdTitle.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ConfigError.invalid("\"holdTitle\" must not be empty")
        }
        guard (1...Config.maxLookaheadDays).contains(lookaheadDays) else {
            throw ConfigError.invalid("\"lookaheadDays\" must be between 1 and \(Config.maxLookaheadDays)")
        }
        guard skipTitleKeywords.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw ConfigError.invalid("\"skipTitleKeywords\" must not contain empty strings")
        }
    }
}

extension Config: Codable {
    private enum CodingKeys: String, CodingKey {
        case calendars, holdTitle, lookaheadDays, skipAllDay, skipTentative, skipUnaccepted, skipTitleKeywords,
             mergeOverlappingHolds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calendars = try c.decodeIfPresent([CalendarEntry].self, forKey: .calendars) ?? []
        holdTitle = try c.decodeIfPresent(String.self, forKey: .holdTitle) ?? Config.defaultHoldTitle
        lookaheadDays = try c.decodeIfPresent(Int.self, forKey: .lookaheadDays) ?? Config.defaultLookaheadDays
        skipAllDay = try c.decodeIfPresent(Bool.self, forKey: .skipAllDay) ?? true
        skipTentative = try c.decodeIfPresent(Bool.self, forKey: .skipTentative) ?? false
        skipUnaccepted = try c.decodeIfPresent(Bool.self, forKey: .skipUnaccepted) ?? false
        skipTitleKeywords = try c.decodeIfPresent([String].self, forKey: .skipTitleKeywords) ?? []
        mergeOverlappingHolds = try c.decodeIfPresent(Bool.self, forKey: .mergeOverlappingHolds) ?? false
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case fileNotFound(URL)
    case invalidJSON(URL, Error)
    case invalid(String)

    public var description: String {
        switch self {
        case .fileNotFound(let url):
            return "config file not found at \(url.path). Copy config.example.json there and edit it."
        case .invalidJSON(let url, let error):
            return "could not parse \(url.path): \(error)"
        case .invalid(let message):
            return "invalid config: \(message)"
        }
    }
}
