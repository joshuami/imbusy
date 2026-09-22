import Foundation
import ImBusyCore

/// Minimal logging: timestamps on top-level lines so launchd logs stay readable, indented detail lines.
struct Output {
    var verbose: Bool

    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE yyyy-MM-dd HH:mm"
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func line(_ text: String) {
        print("[\(Self.timestamp.string(from: Date()))] \(text)")
    }

    func detail(_ text: String) {
        print("  \(text)")
    }

    func debug(_ text: String) {
        if verbose { print("  \(text)") }
    }

    func warn(_ text: String) {
        FileHandle.standardError.write(Data("[\(Self.timestamp.string(from: Date()))] warning: \(text)\n".utf8))
    }

    func error(_ text: String) {
        FileHandle.standardError.write(Data("[\(Self.timestamp.string(from: Date()))] error: \(text)\n".utf8))
    }

    static func span(_ start: Date, _ end: Date) -> String {
        let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
        return "\(dateTime.string(from: start))–\(sameDay ? time.string(from: end) : dateTime.string(from: end))"
    }

    static func day(_ date: Date) -> String { day.string(from: date) }
}
