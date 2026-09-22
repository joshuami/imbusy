# imbusy

Keeps "Hold" events in sync across the calendars on your Mac.

If you manage several calendar accounts (different clients, different employers, Google and
Microsoft 365 side by side), a meeting on one of them leaves you looking free on the others.
imbusy fixes that: whenever an event lands on one calendar in a configured set, it places a
"Hold" at the same time on every other calendar in the set. Reschedule or cancel the event and
the holds follow. Nothing about the event itself is copied, so nothing about one client ever
appears on another client's calendar.

It works entirely through the accounts you have already added in **System Settings > Internet
Accounts**, using Apple's EventKit framework. No OAuth grants, no tenant admin approval, no
third-party services. Holds are ordinary events, so they sync to the servers the same way
anything you create in Calendar.app does.

Optionally, one calendar can receive full copies instead of bare holds, so that a single calendar
shows everything you have on. See "Detailed copies on one calendar".

## How it works

`imbusy sync` runs a single reconciliation pass:

1. Load the config and resolve each calendar by account and calendar name.
2. Fetch every event from now until `lookaheadDays` ahead on every calendar in the set.
   Recurring events are expanded into their individual occurrences.
3. Classify each event as a **hold** (carries the imbusy marker) or a **source** event.
4. Ignore source events that you declined, that are marked free, that are cancelled, or
   (by default) that are all-day.
5. For each remaining source event, make sure exactly one hold with the same start and end
   exists on every other calendar in the set. Create it if missing, update it if it moved.
6. Delete any hold whose source no longer exists, no longer qualifies, or moved out of the window.
7. Save and print a summary.

There is no local database. Everything needed to reconcile is on the calendars themselves,
in each hold's marker, so the tool is stateless, safe to run as often as you like, and a
second run with no changes does nothing.

launchd runs it on a schedule (every ten minutes by default). Polling is deliberate: macOS
has no "event created" trigger, and polling also catches reschedules, cancellations, and
changes made on other devices.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15 or later, or the Command Line Tools with a Swift 5.9+ toolchain
- The calendar accounts added as macOS Internet Accounts and visible in Calendar.app

## Install

```sh
git clone https://github.com/<you>/imbusy.git
cd imbusy
scripts/install.sh
```

On first run the installer builds the release binary, copies it to `~/.local/bin/imbusy`,
writes a starter config to `~/.config/imbusy/config.json`, and stops so you can edit it.
Then:

```sh
~/.local/bin/imbusy list-calendars          # find the exact account and calendar names
$EDITOR ~/.config/imbusy/config.json        # put them in the config
~/.local/bin/imbusy sync --dry-run --verbose  # check the plan against your real calendars
scripts/install.sh                          # load the launchd agent
```

The second `install.sh` writes `~/Library/LaunchAgents/local.imbusy.sync.plist`, loads it,
and runs the first sync immediately. Options:

```
scripts/install.sh --interval 300      # seconds between runs (default 600)
scripts/install.sh --prefix /some/dir  # where to put the binary (default ~/.local/bin)
```

Logs go to `~/Library/Logs/imbusy/imbusy.log` and `imbusy.err.log`.

## First run: calendar permission

imbusy needs **Full Access** to Calendars. macOS ties that permission to the executable that
asks for it, using the `NSCalendarsFullAccessUsageDescription` in the Info.plist embedded in the
binary. Two things follow from that:

**The prompt appears when launchd first runs the agent.** `install.sh` loads the agent with
`RunAtLoad`, so within a few seconds of loading you should see "imbusy would like full access to
your calendar". Click **Allow Full Access**. If you miss it, run
`launchctl kickstart -k gui/$(id -u)/local.imbusy.sync` to trigger another attempt, or grant
access by hand in **System Settings > Privacy & Security > Calendars**.

**Running from Terminal grants Terminal, not imbusy.** When you run `imbusy list-calendars`
from a Terminal window, macOS treats Terminal as the responsible app and the prompt says
"Terminal would like to access your calendar". Allow it; that lets you use the CLI interactively.
The launchd agent is a separate process tree and gets its own prompt as described above, so you
will typically see the prompt twice: once for Terminal, once for the agent. Both should say
Full Access.

**Do not run it from an editor's integrated terminal.** VS Code and similar apps ship without a
calendar usage description in their Info.plist. macOS attributes the request to the editor, finds
no usage string, and denies silently: no prompt, no entry in the Calendars pane, and imbusy
reports "calendar access was not granted" immediately. Use Terminal.app (or iTerm2) for
interactive runs, or let the launchd agent run it.

**Rebuilding may re-trigger the prompt.** `install.sh` ad-hoc signs the binary (SwiftPM's own
"linker-signed" output does not bind the embedded Info.plist to the signature), and the
permission grant is keyed to that signature. If you rebuild and reinstall, expect one more
prompt. To avoid it, sign with a stable identity:

```sh
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/install.sh
```

If a run fails with "calendar access is denied" (exit code 3), check the Calendars pane in
Privacy & Security; if imbusy is missing from the list entirely, the binary has never been
allowed to ask, so kickstart the agent or run it once from Terminal.

## Configuration

`~/.config/imbusy/config.json` (or `$XDG_CONFIG_HOME/imbusy/config.json`). A starter copy is
in [config.example.json](config.example.json):

```json
{
  "calendars": [
    { "account": "Client One (Google)", "calendar": "Calendar", "label": "One" },
    { "account": "Client Two (Microsoft)", "calendar": "Calendar", "label": "Two" },
    { "account": "Personal", "calendar": "Work", "receivesDetails": false }
  ],
  "holdTitle": "Hold",
  "lookaheadDays": 30,
  "skipAllDay": true,
  "skipTentative": false,
  "skipUnaccepted": false,
  "skipTitleKeywords": ["New Event"],
  "mergeOverlappingHolds": false
}
```

| Field | Default | Meaning |
| --- | --- | --- |
| `calendars` | required | At least two entries. `account` is the account name exactly as `list-calendars` prints it (the description you gave it in Internet Accounts), `calendar` is the calendar name. Add `"calendarIdentifier": "..."` (also printed by `list-calendars`) only if two calendars share the same account and calendar name. |
| `calendars[].label` | none | Short name for the calendar, used as a `[label]` prefix on titles copied to a calendar that receives details. |
| `calendars[].receivesDetails` | `false` | This calendar gets detailed copies of the other calendars' events instead of bare holds. See "Detailed copies on one calendar". |
| `holdTitle` | `"Hold"` | Title of the hold events. Changing it renames existing holds on the next run. |
| `lookaheadDays` | `30` | How far ahead to sync. Maximum 1460 (EventKit's four-year limit). |
| `skipAllDay` | `true` | Ignore all-day events. |
| `skipTentative` | `false` | Ignore events whose status is tentative or that you replied "maybe" to. |
| `skipUnaccepted` | `false` | Ignore invitations you have not responded to yet (no reply, or no reply recorded by the server). Events you organised yourself have no reply to give and are always included. Accepting an invitation later creates its holds on the next run. |
| `skipTitleKeywords` | `[]` | Ignore source events whose title contains any of these words. Matching is whole-word and case-insensitive: `"Hold"` matches "Hold", "HOLD: travel" and "Standup (hold)" but not "Stakeholder sync". Multi-word phrases work too: the example's `"New Event"` skips events left with Calendar.app's default title. Use it for placeholder events and for holds you created by hand before adopting imbusy, so they do not get holds of their own. imbusy's own holds are recognised by their marker, never by title, so this setting cannot hide them. |
| `mergeOverlappingHolds` | `false` | Reserved for a later feature. Setting it to `true` prints a warning and has no other effect. |

Every calendar in the set is both a source and a target. Read-only and subscribed calendars
can still be sources (their events get holds elsewhere) but cannot receive holds; imbusy
warns about them on every run.

## Detailed copies on one calendar

Set `"receivesDetails": true` on one calendar and, instead of bare holds, it receives a copy of
each qualifying event from the other calendars: title, location, URL and notes, which is where
Meet, Teams and Zoom links live. Give the other calendars a `label` and copied titles read
"[Acme] Design check-in". You can then show only that one calendar and still see your whole day.
The other calendars keep getting bare holds, so nothing changes for them.

Copies are still holds: they carry the marker, never spawn holds of their own, follow the source
when it moves or changes, disappear when it is cancelled or declined, and are removed by `purge`.
The marker also records a hash of the copied content, so a copy is rewritten only when the
source actually changes, not on every run. Turning the flag on upgrades existing bare holds in
place; turning it off strips them back to bare holds.

What is never copied: attendees (adding them would send invitations) and alerts.

Two things to be aware of:

- **This is a deliberate privacy trade-off.** Details from every calendar in the set end up on
  the receiving calendar's server. If that is a personal Google or iCloud account, check that
  your clients' or employer's policies allow their meeting details to live there. Everything
  else in imbusy is built so that no such leak happens; this flag opts into one.
- **Copies are one-way.** Joining a meeting from the copied link works. Replying, editing, or
  declining must happen on the original, and any edit you make to a copy is overwritten on the
  next run.

## Usage

```
imbusy sync [--dry-run] [--verbose] [--config PATH]
imbusy list-calendars
imbusy purge [--dry-run] [--all] [--config PATH]
imbusy probe --calendar "Account / Calendar" [--check | --cleanup]
```

**Dry run first.** `imbusy sync --dry-run --verbose` prints every hold it would create, update
or delete, every source event it skipped and why, and changes nothing:

```
[2026-09-21 09:00:02] dry run: 3 calendars, 2026-09-21 to 2026-10-21
  + would create  Client Two (Microsoft) / Calendar  "Hold"  Tue 2026-09-23 10:00–11:00  <- Client One (Google) / Calendar
  + would create  Personal / Work  "Hold"  Tue 2026-09-23 10:00–11:00  <- Client One (Google) / Calendar
  - would delete  Personal / Work  "Hold"  Mon 2026-09-22 15:00–15:30  (source missing or no longer qualifies)
    skip    Client One (Google) / Calendar  "Company offsite"  Fri 2026-09-26 00:00–Sat 2026-09-27 00:00  (all-day)
[2026-09-21 09:00:02] dry run: would create 2, update 0, delete 1; skipped 1 (all-day 1); 14 source events, 26 holds found
```

**`purge`** deletes every hold imbusy created on the configured calendars, scanning one year
back and three years ahead. Use `--all` to scan every writable calendar EventKit can see, for
example after removing a calendar from the config. Combine with `--dry-run` to preview.

**`probe`** checks that the marker survives a round trip through your calendar server. See the
next section.

Exit codes: 0 success, 1 failure, 2 usage error, 3 no calendar access.

## Marker field

Each hold must carry enough information to find its source again on the next run, and that
information must survive being pushed to Google or Exchange and pulled back. The marker is a
single line stored in the hold's **notes**:

```
imbusy:v1 src=3f9a1c0b7d2e4a68 evt=abc123%40google.com occ=20260923T100000Z
```

- `src` is a truncated SHA-256 of the source calendar's configured account and calendar name.
  It is deterministic, so it survives reinstalls and works across machines, and it is opaque,
  so the hold on one client's calendar reveals nothing about the other client.
- `evt` is the source event's server-side identifier (the iCalendar UID, percent-encoded).
  Unlike EventKit's local `eventIdentifier`, the UID is the same on every device and after
  re-adding the account.
- `occ` is the original start of the occurrence, for recurring events. Each occurrence of a
  recurring event maps to its own hold; a single occurrence that was moved keeps its original
  `occ` and its hold is updated rather than replaced. Single events use `-`.

Why notes rather than the URL field: the notes/description field is a first-class property on
Google Calendar, Exchange and iCloud alike, and both the CalDAV and Exchange transports carry it.
The URL field is an iCalendar `URL` property that Google Calendar has no equivalent for and that
the Exchange transport does not map reliably, so it may come back empty. Exchange does convert
plain-text notes to HTML and back, which can change whitespace and line breaks, so the parser
tolerates HTML wrapping, CRLF, and surrounding text.

This reasoning is documented rather than measured. To verify it against your own accounts, use
the probe, which writes a marker into both fields of a free, fifteen-minute event dated
yesterday, and reports which fields come back intact after the server has synced:

```sh
imbusy probe --calendar "Client One (Google) / Calendar"
# wait a few minutes for Calendar.app to push and pull
imbusy probe --calendar "Client One (Google) / Calendar" --check
imbusy probe --calendar "Client One (Google) / Calendar" --cleanup
```

If a server strips the notes entirely, the hold would come back looking like a real event and
imbusy would start making holds of holds. Run the probe once per account type before enabling
the agent. If you find an account where notes do not survive, please open an issue.

## Uninstall

```sh
scripts/uninstall.sh --purge   # delete all holds, unload the agent, remove the binary
scripts/uninstall.sh --all     # also remove the config and logs
```

Without `--purge`, the holds already on your calendars stay where they are. You can remove them
later with `imbusy purge` as long as the binary is still installed. To revoke calendar access
afterwards, remove imbusy in System Settings > Privacy & Security > Calendars.

## Limitations

- **The Mac must be awake.** launchd does not wake the machine to run the agent, and syncs
  missed while asleep run when it wakes.
- **Minutes, not seconds.** A hold is created locally and becomes visible to others only after
  Calendar.app has pushed it to the server. Add the sync interval and the account's refresh
  interval together for the worst case.
- **Overlapping events produce overlapping holds.** Two source events at the same time on
  different calendars each get their own hold everywhere else. `mergeOverlappingHolds` is
  reserved for a later version.
- **Read-only and subscribed calendars cannot receive holds.** imbusy detects them and warns
  on every run; their own events still generate holds on the writable calendars.
- **An invitation sent to two of your accounts** appears as a source event on both, so each one
  gets a hold on the other. The hold and the real event overlap harmlessly.
- **Server-side default reminders.** imbusy creates holds with no alerts, but Google Calendar
  may apply your calendar's default notifications to events created through CalDAV. Turn off
  default notifications for that calendar in Google Calendar's settings if this bothers you.
- **Past holds are left alone.** Only the window from now to `lookaheadDays` is reconciled, so
  holds for past events remain as a record. `purge` removes them.
- **Detailed copies are only as good as the source fields.** A Google Meet link created in Google
  Calendar's own UI appears in the notes or URL over CalDAV; a Teams link is in the location and
  notes over Exchange. Links held only in server-side conference data that the transport does not
  expose will not be copied.
- **Hand-made holds are source events.** An event you titled "Hold" yourself has no marker, so
  imbusy treats it as real busy time and holds it on the other calendars. Add `"Hold"` to
  `skipTitleKeywords` to ignore such events, or delete them and let imbusy recreate coverage.
- **Calendar names are part of the marker.** Renaming an account or calendar in the config
  changes its key; the next run deletes the old holds and creates new ones.

## Troubleshooting

**`calendar "X / Y" not found`.** Names must match exactly what `list-calendars` prints,
including the account description from Internet Accounts (which is often just "Google" or
"Exchange" until you rename it). Two accounts with the same description cannot be told apart by
name; rename one in System Settings > Internet Accounts, or use `calendarIdentifier`.

**`calendar access was not granted` with no prompt and nothing in the Calendars pane.** You ran
it from an editor's integrated terminal. See "First run: calendar permission"; use Terminal.app or
the agent. To confirm, look for `auth_reason=5` ("missing usage string") in the TCC log:

```sh
/usr/bin/log show --last 10m --info --predicate 'process == "tccd" AND eventMessage CONTAINS "kTCCServiceCalendar"' | grep -E "responsible=|auth_reason"
```

**`calendar access is denied`, exit code 3.** See "First run: calendar permission". Check the
Calendars pane in Privacy & Security, and remember that Terminal and the launchd agent are
granted separately.

**Nothing appears in the log.** Check that the agent is loaded with
`launchctl print gui/$(id -u)/local.imbusy.sync`. If it is not, run `scripts/install.sh` again
and read its output. If it is, run `launchctl kickstart -k gui/$(id -u)/local.imbusy.sync` and
tail `~/Library/Logs/imbusy/imbusy.err.log`.

**Holds are created but do not reach the server.** That is Calendar.app's job. Open
Calendar.app, choose View > Refresh Calendars, and check the account's refresh interval in
Calendar > Settings > Accounts.

**Holds keep multiplying.** The marker is not surviving the round trip on one of your accounts.
Stop the agent (`launchctl bootout gui/$(id -u)/local.imbusy.sync`), run `imbusy purge`, and
use `probe` to find the account at fault.

**A hold points at an event that no longer exists but is not deleted.** The hold is outside the
sync window (more than `lookaheadDays` ahead, or in the past). Increase `lookaheadDays` or run
`purge` and let the next sync recreate the current holds.

## Development

```sh
swift build
swift test
codesign --force --sign - .build/debug/imbusy   # bind the Info.plist to the signature
.build/debug/imbusy sync --dry-run --config ./config.json   # from Terminal.app, not an editor terminal
```

The package has three targets:

- `ImBusyCore`: config, marker, and the reconciler. Pure Swift, no EventKit, unit-tested with an
  in-memory fake store.
- `ImBusyEventKit`: the `CalendarStore` implementation on top of EventKit.
- `imbusy`: the command-line tool.

Continuous integration builds and tests on macOS via GitHub Actions.

## License

MIT. See [LICENSE](LICENSE).
