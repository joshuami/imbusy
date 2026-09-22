> This is the original brief the project was built from, kept for the design rationale. Where it and the [README](../README.md) disagree, the README is current.

# Project brief: I'm Busy - a calendar hold sync for macOS

## Problem

I manage several calendar accounts for different clients across Google Calendar and Microsoft 365. All of them are added as macOS Internet Accounts and visible in Calendar.app. When I create an event or accept an invite on one calendar, I want a "Hold" event marking me busy at the same time on each of the other calendars in a configured set. Doing this by hand is tedious and error-prone.

## Approach

A small command-line tool written in Swift, using EventKit, run on a schedule by launchd. It polls rather than reacting to triggers, because macOS offers no "event created" trigger, and because polling also covers reschedules, cancellations, and changes made on other devices.

Do not use AppleScript or Automator for the sync logic. Calendar's AppleScript interface is slow and does not expand recurring events. EventKit's date-range predicate returns each occurrence.

Because it works through the existing macOS Internet Accounts, no OAuth grants or tenant admin approvals are needed.

## Sync algorithm (each run)

1. Load config. Resolve each configured calendar by account and calendar name.
2. Fetch events from now to now + lookahead days for every calendar in the sync set.
3. Classify each event as a hold (carries our marker) or a source event.
4. Ignore source events that are: declined by me, marked free/available, cancelled, or (configurable) all-day.
5. For each remaining source event, ensure exactly one hold exists on every other calendar in the set, with matching start and end. Create it if missing; update it if the time changed.
6. Delete any hold whose source event no longer exists, no longer qualifies, or has moved outside the window's match.
7. Save changes and log a summary (created, updated, deleted, skipped).

### Marker and idempotency

Each hold carries a marker identifying it as ours and naming its source, for example in the notes or URL field: a fixed prefix plus the source calendar identifier, the source event identifier, and the occurrence start date (needed so each occurrence of a recurring event maps to its own hold). Verify which field survives a round trip through both Google and Exchange, since servers may rewrite or strip some fields; choose the one that does, and document the finding.

The marker is what prevents holds from spawning further holds. The tool must be stateless (no local database) and safe to run repeatedly with no changes on the second run.

### Hold properties

- Title: configurable, default "Hold"
- Availability: busy (where the calendar supports setting it)
- No attendees, no alerts, no location, no copied details from the source event. Nothing about one client may leak onto another client's calendar.

## Configuration

A user-editable file, e.g. `~/.config/calendar-hold-sync/config.json` (or YAML/TOML if there's a good reason). Nothing personal is hardcoded or committed. Fields:

- list of calendars in the sync set, each identified by account name + calendar name
- hold title
- lookahead days (default 30)
- skip all-day events (default true)
- skip tentative events (default false)
- optional: merge overlapping holds (default false; can be a later feature)

Ship a `config.example.json` with placeholder names.

## CLI

- `sync` : run one reconciliation pass
- `--dry-run` : print what would be created, updated, or deleted, and change nothing
- `list-calendars` : print every account and calendar EventKit can see, so users can copy exact names into the config
- `purge` : remove every hold the tool has created (clean uninstall)
- `--verbose`

## Permissions

The tool needs full calendar access (`requestFullAccessToEvents` on macOS 14+, with a fallback for earlier versions if we support them). The binary needs an embedded Info.plist containing `NSCalendarsFullAccessUsageDescription`, since the TCC prompt attaches to the executable. Work out and document the cleanest way to get the permission prompt to appear for a launchd-run binary (typically: run it once interactively from Terminal first).

## Scheduling

Provide a launchd user agent plist template with a configurable interval (default 600 seconds), logging stdout and stderr to `~/Library/Logs/`. Provide `install.sh` and `uninstall.sh` that build the release binary, copy it to a sensible location, fill in the plist template, and load or unload the agent.

## Repository requirements (this will be public on GitHub)

- Swift Package Manager project, no third-party dependencies unless clearly justified
- README covering: what it does and why, requirements, install, configuration, first-run permission step, dry-run usage, uninstall, limitations, troubleshooting
- MIT license
- `.gitignore` for Swift/Xcode/macOS
- No personal data, client names, or real calendar names anywhere in the repo or its history
- Core reconciliation logic separated from EventKit behind a protocol so it can be unit-tested with fake calendars; include tests for: create, update on reschedule, delete on cancel, no hold-of-hold, recurring occurrences, idempotent second run
- A simple GitHub Actions workflow that builds and runs tests on macOS

## Known limitations to document

- The Mac must be awake for syncs to run
- Holds appear to others only after Calendar.app syncs to the server, so expect minutes, not seconds
- Overlapping source events produce multiple holds unless merging is enabled
- Read-only or subscribed calendars cannot receive holds; detect and warn

## How I'd like you to proceed

1. Read this brief and ask me about anything ambiguous before writing code.
2. Scaffold the package, then implement `list-calendars` first so I can confirm EventKit sees all my accounts.
3. Implement `sync --dry-run` next, and let me check its output against my real calendars before enabling writes.
4. Then writes, `purge`, the launchd installer, tests, and README.