import EventKit
import Foundation
import ImBusyCore
import ImBusyEventKit

let version = "0.1.0"

enum ExitCode: Int32 {
    case ok = 0
    case failure = 1
    case usage = 2
    case noAccess = 3
}

struct CLIError: Error, CustomStringConvertible {
    var description: String
    var code: ExitCode = .failure
}

@main
struct ImBusy {
    static func main() async {
        let options: Options
        do {
            options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n\n\(usageText)\n".utf8))
            exit(ExitCode.usage.rawValue)
        }

        if options.version {
            print("imbusy \(version)")
            return
        }
        if options.help || options.command == nil {
            print(usageText)
            exit(options.command == nil && !options.help ? ExitCode.usage.rawValue : ExitCode.ok.rawValue)
        }

        let out = Output(verbose: options.verbose)
        do {
            switch options.command! {
            case .listCalendars: try await listCalendars(options, out)
            case .sync: try await sync(options, out)
            case .purge: try await purge(options, out)
            case .probe: try await probe(options, out)
            }
        } catch let error as CLIError {
            out.error(error.description)
            exit(error.code.rawValue)
        } catch {
            out.error("\(error)")
            exit(ExitCode.failure.rawValue)
        }
    }

    // MARK: Shared

    static func configURL(_ options: Options) -> URL {
        if let path = options.configPath {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return Config.defaultURL
    }

    /// Make sure we hold full calendar access, prompting if the user has not decided yet.
    static func authorizedStore(_ out: Output) async throws -> EventKitStore {
        let ekStore = EKEventStore()
        switch CalendarAccess.status() {
        case .fullAccess:
            break
        case .notDetermined:
            out.line("requesting calendar access; look for the system prompt")
            let granted = try await CalendarAccess.requestFullAccess(store: ekStore)
            guard granted else {
                throw CLIError(description: "calendar access was not granted. " + accessHint, code: .noAccess)
            }
        case .writeOnly:
            throw CLIError(description: "imbusy has write-only calendar access but needs full access. " + accessHint,
                           code: .noAccess)
        case .denied, .restricted, .unknown:
            throw CLIError(description: "calendar access is denied. " + accessHint, code: .noAccess)
        }
        return EventKitStore(store: ekStore)
    }

    static let accessHint = "If no prompt appeared and imbusy is missing from System Settings > Privacy & Security > "
        + "Calendars, you probably ran it from an editor's integrated terminal (VS Code, etc.): macOS attributes the "
        + "request to that app, which has no calendar usage description, and denies silently. Run it from Terminal.app "
        + "or let the launchd agent run it. Otherwise enable imbusy in that Calendars pane. "
        + "See README, \"First run: calendar permission\"."

    static func loadConfig(_ options: Options, _ out: Output) throws -> Config {
        let url = configURL(options)
        let config = try Config.load(from: url)
        out.debug("config: \(url.path)")
        if config.mergeOverlappingHolds {
            out.warn("mergeOverlappingHolds is not implemented yet; holds are created per source event")
        }
        return config
    }

    static func resolve(_ config: Config, _ store: EventKitStore, _ out: Output) throws -> [SyncCalendar] {
        let calendars = try SyncRunner.resolveCalendars(config: config, store: store)
        for calendar in calendars {
            var flags: [String] = []
            if !calendar.isWritable { flags.append("read-only") }
            if !calendar.supportsBusyAvailability { flags.append("no busy/free support") }
            out.debug("calendar: \(calendar.ref)\(flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]")")
            if !calendar.isWritable {
                out.warn("calendar \(calendar.ref) is read-only; its events get holds elsewhere but it cannot receive holds")
            }
        }
        return calendars
    }

    // MARK: list-calendars

    static func listCalendars(_ options: Options, _ out: Output) async throws {
        let store = try await authorizedStore(out)
        let calendars = try store.allCalendars()
        if calendars.isEmpty {
            print("EventKit sees no calendars. Check System Settings > Internet Accounts.")
            return
        }
        var byAccount: [String: [CalendarInfo]] = [:]
        for calendar in calendars { byAccount[calendar.account, default: []].append(calendar) }
        for account in byAccount.keys.sorted() {
            let entries = byAccount[account]!
            print("\(account)  (\(entries.first!.accountType))")
            for entry in entries {
                var flags: [String] = []
                if !entry.isWritable { flags.append("read-only") }
                if entry.isSubscribed { flags.append("subscribed") }
                let suffix = flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]"
                print("  \(entry.calendar)\(suffix)")
                print("      identifier: \(entry.identifier)")
            }
            print("")
        }
        print("Config entries look like: { \"account\": \"<account>\", \"calendar\": \"<calendar>\" }")
        print("Add \"calendarIdentifier\" only if two calendars share the same account and calendar name.")
    }

    // MARK: sync

    static func sync(_ options: Options, _ out: Output) async throws {
        let config = try loadConfig(options, out)
        let store = try await authorizedStore(out)
        let calendars = try resolve(config, store, out)
        let now = Date()
        let window = SyncRunner.window(now: now, lookaheadDays: config.lookaheadDays)
        let mode = options.dryRun ? "dry run" : "sync"
        out.line("\(mode): \(calendars.count) calendars, \(Output.day(window.start)) to \(Output.day(window.end))")

        let plan = try SyncRunner.planSync(config: config, calendars: calendars, store: store, now: now)
        report(plan, options, out)

        if options.dryRun {
            out.line("dry run: would create \(plan.creates.count), update \(plan.updates.count), "
                + "delete \(plan.deletes.count); \(skippedSummary(plan)); "
                + "\(plan.sourceCount) source events, \(plan.holdCount) holds found")
            return
        }
        if plan.isEmpty {
            out.line("nothing to do; \(skippedSummary(plan)); \(plan.sourceCount) source events, \(plan.holdCount) holds")
            return
        }
        let result = try SyncRunner.apply(plan, store: store)
        for failure in result.failures { out.error(failure) }
        out.line("created \(result.created), updated \(result.updated), deleted \(result.deleted); "
            + "\(skippedSummary(plan)); \(plan.sourceCount) source events, \(plan.holdCount) holds found"
            + (result.failures.isEmpty ? "" : "; \(result.failures.count) failed"))
        if !result.failures.isEmpty { exit(ExitCode.failure.rawValue) }
    }

    static func skippedSummary(_ plan: Plan) -> String {
        guard !plan.skipped.isEmpty else { return "skipped 0" }
        let parts = plan.skippedByReason.map { "\($0.0.rawValue) \($0.1)" }
        return "skipped \(plan.skipped.count) (\(parts.joined(separator: ", ")))"
    }

    static func report(_ plan: Plan, _ options: Options, _ out: Output) {
        for warning in plan.warnings { out.warn(warning) }
        let prefix = options.dryRun ? "would " : ""
        for create in plan.creates {
            var text = "+ \(prefix)create  \(create.target.ref)  \"\(create.spec.title)\"  \(Output.span(create.spec.start, create.spec.end))"
            text += "  <- \(create.source.calendar)"
            if options.verbose {
                text += ": \"\(create.source.title)\"  [\(create.source.externalID.suffix(10))"
                text += create.source.occurrenceDate.map { " @\(Output.day($0))" } ?? ""
                text += "]"
            }
            out.detail(text)
        }
        for update in plan.updates {
            var text = "~ \(prefix)update  \(update.existing.calendar)  \"\(update.existing.title)\"  "
                + Output.span(update.existing.start, update.existing.end)
            if update.changes.contains("start") || update.changes.contains("end") {
                text += " -> \(Output.span(update.spec.start, update.spec.end))"
            }
            if update.changes.contains("title") { text += " -> \"\(update.spec.title)\"" }
            out.detail(text + "  (\(update.changes.joined(separator: ", ")))")
        }
        for delete in plan.deletes {
            out.detail("- \(prefix)delete  \(delete.existing.calendar)  \"\(delete.existing.title)\"  "
                + "\(Output.span(delete.existing.start, delete.existing.end))  (\(delete.reason.rawValue))")
        }
        if options.verbose {
            for skipped in plan.skipped {
                out.detail("  skip    \(skipped.event.calendar)  \"\(skipped.event.title)\"  "
                    + "\(Output.span(skipped.event.start, skipped.event.end))  (\(skipped.reason.rawValue))")
            }
        }
    }

    // MARK: purge

    static func purge(_ options: Options, _ out: Output) async throws {
        let config = try loadConfig(options, out)
        let store = try await authorizedStore(out)
        let calendars: [SyncCalendar]
        if options.all {
            calendars = try store.allCalendars().filter(\.isWritable).map {
                try store.resolve(Config.CalendarEntry(account: $0.account, calendar: $0.calendar,
                                                       calendarIdentifier: $0.identifier))
            }
        } else {
            calendars = try resolve(config, store, out)
        }
        // Holds may exist well outside the sync window (past holds are left in place as history,
        // and lookaheadDays may have been larger before). Scan one year back and three years ahead,
        // which stays under EventKit's four-year predicate limit.
        let now = Date()
        let window = DateInterval(start: now.addingTimeInterval(-365 * 86_400), end: now.addingTimeInterval(3 * 365 * 86_400))
        out.line("\(options.dryRun ? "dry run purge" : "purge"): \(calendars.count) calendars, "
            + "\(Output.day(window.start)) to \(Output.day(window.end))")
        let plan = try SyncRunner.planPurge(config: config, calendars: calendars, store: store, window: window)
        report(plan, options, out)
        if options.dryRun {
            out.line("dry run: would delete \(plan.deletes.count) holds")
            return
        }
        let result = try SyncRunner.apply(plan, store: store)
        for failure in result.failures { out.error(failure) }
        out.line("deleted \(result.deleted) holds" + (result.failures.isEmpty ? "" : "; \(result.failures.count) failed"))
        if !result.failures.isEmpty { exit(ExitCode.failure.rawValue) }
    }

    // MARK: probe

    static func probe(_ options: Options, _ out: Output) async throws {
        guard let name = options.calendar else {
            throw CLIError(description: "probe needs --calendar \"Account / Calendar\"", code: .usage)
        }
        let parts = name.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else {
            throw CLIError(description: "--calendar must be written as \"Account / Calendar\"", code: .usage)
        }
        let store = try await authorizedStore(out)
        let calendar = try store.resolve(Config.CalendarEntry(account: parts[0], calendar: parts[1]))
        guard calendar.isWritable else {
            throw CLIError(description: "calendar \(calendar.ref) is read-only and cannot be probed")
        }
        // Probe window: yesterday. Past, free, and short, so it blocks nothing.
        let now = Date()
        let from = now.addingTimeInterval(-3 * 86_400)
        let to = now

        if options.cleanup {
            let count = try store.deleteProbes(in: calendar, from: from, to: to)
            out.line("deleted \(count) probe event(s) on \(calendar.ref)")
            return
        }

        let marker = HoldMarker(sourceCalendarKey: "0123456789abcdef", sourceEventID: "probe-uid@imbusy.invalid",
                                occurrence: now)
        if options.check {
            let probes = try store.probes(in: calendar, from: from, to: to)
            guard !probes.isEmpty else {
                throw CLIError(description: "no probe found on \(calendar.ref). Run `imbusy probe --calendar ...` first "
                    + "and wait for Calendar to sync.")
            }
            for probe in probes {
                let notesOK = HoldMarker.parse(probe.notes) != nil
                let urlText = probe.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                    .queryItems?.first(where: { $0.name == "m" })?.value
                let urlOK = HoldMarker.parse(urlText) != nil
                out.line("probe dated \(Output.span(probe.start, probe.start.addingTimeInterval(15 * 60))) on \(calendar.ref):")
                out.detail("notes field: \(notesOK ? "marker intact" : "marker missing or mangled")")
                out.detail("url field:   \(urlOK ? "marker intact" : "marker missing or mangled")")
                if options.verbose {
                    out.detail("notes: \(probe.notes.map { "\"\($0)\"" } ?? "nil")")
                    out.detail("url:   \(probe.url?.absoluteString ?? "nil")")
                }
            }
            out.line("Run `imbusy probe --calendar \"\(name)\" --cleanup` to remove the probe.")
            return
        }

        try store.createProbe(in: calendar, text: marker.notesText, start: now.addingTimeInterval(-86_400))
        out.line("created probe on \(calendar.ref). Wait a few minutes for Calendar to sync both ways, then run:")
        out.detail("imbusy probe --calendar \"\(name)\" --check")
    }
}
