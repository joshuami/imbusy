import Foundation

enum Command: String {
    case sync
    case listCalendars = "list-calendars"
    case purge
    case probe
}

struct Options {
    var command: Command?
    var dryRun = false
    var verbose = false
    var all = false
    var check = false
    var cleanup = false
    var help = false
    var version = false
    var configPath: String?
    var calendar: String?
}

enum UsageError: Error, CustomStringConvertible {
    case unknownCommand(String)
    case unknownOption(String)
    case missingValue(String)
    case missingCommand

    var description: String {
        switch self {
        case .unknownCommand(let c): return "unknown command \"\(c)\""
        case .unknownOption(let o): return "unknown option \"\(o)\""
        case .missingValue(let o): return "option \"\(o)\" needs a value"
        case .missingCommand: return "no command given"
        }
    }
}

let usageText = """
imbusy — keep "Hold" events in sync across your calendars

USAGE
  imbusy sync [--dry-run] [--verbose] [--config PATH]
  imbusy list-calendars
  imbusy purge [--dry-run] [--all] [--config PATH]
  imbusy probe --calendar "Account / Calendar" [--check | --cleanup] [--config PATH]

COMMANDS
  sync             Run one reconciliation pass over the configured calendars.
  list-calendars   Print every account and calendar EventKit can see.
  purge            Remove every hold imbusy has created on the configured calendars.
  probe            Create, check, or clean up a marker round-trip test event.

OPTIONS
  --dry-run        Print what would change and change nothing.
  --verbose, -v    Also print skipped events and resolved calendars.
  --all            (purge) Scan every writable calendar, not just the configured ones.
  --calendar NAME  (probe) Calendar to probe, as "Account / Calendar".
  --check          (probe) Read the probe back and report which fields survived.
  --cleanup        (probe) Delete probe events.
  --config PATH    Config file (default: ~/.config/imbusy/config.json).
  --help, -h       Show this help.
  --version        Show the version.
"""

func parseArguments(_ args: [String]) throws -> Options {
    var options = Options()
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--dry-run", "-n": options.dryRun = true
        case "--verbose", "-v": options.verbose = true
        case "--all": options.all = true
        case "--check": options.check = true
        case "--cleanup": options.cleanup = true
        case "--help", "-h": options.help = true
        case "--version": options.version = true
        case "--config":
            guard let value = iterator.next() else { throw UsageError.missingValue(arg) }
            options.configPath = value
        case "--calendar":
            guard let value = iterator.next() else { throw UsageError.missingValue(arg) }
            options.calendar = value
        default:
            if arg.hasPrefix("--config=") {
                options.configPath = String(arg.dropFirst("--config=".count))
            } else if arg.hasPrefix("--calendar=") {
                options.calendar = String(arg.dropFirst("--calendar=".count))
            } else if arg.hasPrefix("-") {
                throw UsageError.unknownOption(arg)
            } else if options.command == nil, let command = Command(rawValue: arg) {
                options.command = command
            } else {
                throw UsageError.unknownCommand(arg)
            }
        }
    }
    return options
}
