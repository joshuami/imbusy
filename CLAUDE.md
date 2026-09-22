# imbusy

Swift command-line tool that keeps "Hold" events in sync across macOS calendars via EventKit,
run on a schedule by launchd. The README is the authoritative description; the original design
brief is in `docs/original-brief.md`.

## Layout

- `Sources/ImBusyCore`: config, marker, reconciler. Pure Swift, no EventKit. All logic lives here.
- `Sources/ImBusyEventKit`: the `CalendarStore` implementation on EventKit.
- `Sources/imbusy`: CLI entry point. `Info.plist` is embedded via linker flags in `Package.swift`.
- `Tests/ImBusyCoreTests`: unit tests against `FakeCalendarStore`. No calendar access needed.

## Working on it

- `swift build && swift test`. Every reconciler change needs a test, including an idempotency check
  (a second run after applying the plan must produce an empty plan).
- Keep EventKit out of `ImBusyCore`. New calendar operations go through the `CalendarStore` protocol.
- Anything written onto a hold must be derived only from the marker or, on a calendar with
  `receivesDetails`, from the source event. Never attendees or alarms.
- Never rely on local state; the marker in the hold's notes is the only persistence.

## Running against real calendars

- Run the binary from Terminal.app or via the launchd agent, never from an editor's integrated
  terminal: macOS attributes the permission request to the editor and denies silently.
- Ad-hoc sign after building (`codesign --force --sign - .build/release/imbusy`) so the embedded
  Info.plist is bound to the signature; `scripts/install.sh` does this.
- Use `sync --dry-run --verbose` first. Real calendar names, the user's config
  (`~/.config/imbusy/config.json`), and dry-run output must never be committed or quoted in the repo.
