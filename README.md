# calsync — calendar mirror (macOS)

One-way mirroring between Mac calendars. Each run of the binary syncs a single
source → destination pairing; any topology is a list of such pairings, run one
after another on a schedule:

- **Two-way mirror** = the same pair, both directions.
- **Fan-in** = several sources into one destination (a "busy" aggregate).
- **Fan-out** = one source into several destinations.
- Any mix of the above.

Copies are titled `Busy` (`MIRROR_TITLE`). Only the title, start, and end are
copied — never the location, attendees, notes, or alarms — so no detail from
any calendar leaks onto another. Moves follow. Deletions follow. All-day events
are ignored — including timed events spanning whole midnight-to-midnight days,
which is how Google Calendar stores "Out of office".

Every copy carries a `[sync:]` marker tying it to its exact source occurrence.
The marker is what makes arbitrary pairings composable:

- A pairing never mirrors a marked event, so copies don't re-mirror. That is
  why two-way is just two one-way runs that don't feed back, and why chains
  don't propagate transitively.
- A pairing only manages copies carrying its own `SYNC_SCOPE` tag
  (`[sync:<scope>|<key>]`). **Rule: pairings sharing a destination need
  distinct scopes.** Knowing an event is a copy isn't enough, because
  reconciliation also *deletes*: a run removes any managed copy whose key
  isn't in its source — that's how cancellations propagate. A copy made from
  another source can never match, so without scopes each run wipes the other
  pairing's copies as orphans and the next run re-creates them, forever. The
  key names the source event, not the source calendar, and an orphan's source
  event is gone — the scope is that missing ownership fact written down. A
  destination written by only one pairing can go unscoped: ownership is
  implicit.
- Scope tags are baked into stored markers; never change one once copies exist.

Unmarked events are never touched, so hand-made entries are safe everywhere.

**Destinations are written to.** If one belongs to an employer, note that this
puts events on their server.

`mirror.sh` is a convenience wrapper for this machine's topology — a two-way
pair (`CAL_A` ↔ `CAL_B`) plus an optional aggregate (`CAL_C`) both feed
one-way, scoped `a2c`/`b2c`. A different topology is just different
invocations of the binary; nothing in the engine knows about the wrapper's
shape.

## Why it's built this way

macOS Shortcuts has no short-interval trigger — the built-in automations top out
at once-per-day time triggers. So the cadence comes from a `launchd` agent,
which fires `mirror.sh`, which runs the binary once per direction.

The usual obstacle to running a bare command-line tool from `launchd` is TCC:
a tool with no bundle identity cannot show a Calendars prompt and gets denied
instead. That is what `Info.plist` and the ad-hoc signature are for. The plist
is embedded in the binary's `__TEXT,__info_plist` section, which gives it usage
strings and an identity to hang a permission grant on; approve the prompt once
by running it from Terminal, and `launchd` runs inherit that grant. No Full Disk
Access, and no Shortcut in the middle.

The reconciliation itself is a small Swift program using EventKit rather than
native Shortcuts calendar actions. Two reasons: EventKit expands recurring
meetings into individual occurrences (AppleScript's Calendar dictionary does
not — it only returns the series master, so most work meetings would be
missed), and reliable delete-propagation needs a real diff.

Each mirrored event carries a hidden marker in its notes:

```
[sync:<external-id>@t<occurrence-epoch-in-hex>]
```

That's how a copy is tied back to a specific source occurrence. Events *without*
a marker are never touched in either calendar, so your own hand-made entries are
safe — and it is also what keeps the two directions from feeding each other.

The occurrence stamp is hex behind a `t` so it never forms a run of 10 digits. A
bare decimal epoch is read by the macOS data detectors as a US phone number, and
Calendar renders it as a tappable phone link on every copy. An ISO timestamp
would trip the *date* detector instead, so hex it is.

Markers written in the older `@<decimal-epoch>` form are rewritten on read, so an
existing copy is still recognised and gets an in-place update rather than being
deleted and re-created. External identifiers can themselves contain an `@`
(Google-backed calendars use `…@google.com`), so the occurrence stamp is always
split off at the **last** `@`.

The marker is the single point of failure for the whole design. It lives in the
event's notes, so anything that rewrites notes on either server breaks the loop
protection and the mirror starts duplicating. It has been verified to survive a
full round-trip on both Exchange and a CalDAV server; `MAX_CREATES` is the
backstop if that ever stops being true.

## Files

| File | Purpose |
|---|---|
| `calsync.swift` | The sync engine |
| `mirror.sh` | Runs the engine once per direction; installed as `~/bin/calsync-mirror` |
| `Info.plist` | Usage strings embedded in the binary so the TCC prompt can appear |
| `build.sh` | Compiles + ad-hoc signs to `~/bin/calsync`, installs the wrapper |
| `com.weitzman.calsync.plist` | LaunchAgent, `StartInterval 600` |

The LaunchAgent label and the signing identifier in `build.sh` use a reverse-DNS
name. Change both to your own if you like — but note the identifier is what TCC
ties the Calendars grant to, so changing it means approving the permission
prompt once more.

## Setup

### 1. Build

```bash
chmod +x build.sh
./build.sh
```

Needs Xcode command line tools (`xcode-select --install`).

### 2. Find your calendar names and ids

To look up a calendar's id, run `calsync` with a title that matches nothing —
it prints every calendar as `"title" (account, id …)` and exits:

```bash
SRC_CAL='__nope__' ~/bin/calsync
```

```
ERROR: source calendar "__nope__" not found. Available:
"Calendar" (Exchange, id 50898AAD-6794-496A-AC50-AF918F470C60),
"Personal" (iCloud, id 440D9427-CA71-428A-8A05-9AE2C8F66311), …
```

The id is the UUID after `id`; that is the value for the `_ID` variables. There
is no way to see it in the Calendar app — it's an EventKit-level identifier —
so this listing is the lookup. Titles, when you do use them, must match the
Calendar sidebar exactly.

The same listing is printed whenever a configured title or id fails to resolve,
so a stale id shows you the current ids for re-pinning.

Prefer
pinning by identifier (`SRC_CAL_ID`/`DST_CAL_ID`, or `CAL_A_ID`/`CAL_B_ID` for
the wrapper): titles are neither unique — a work account and the local account
are both often called `Calendar` — nor stable. Exchange in particular reverts
renames of its default calendar, which turns a title-pinned mirror into a brick
days later. When an id is set the title is ignored entirely; identifiers only
change if the account itself is removed and re-added.

### 3. Dry run

This is also what triggers the Calendars permission prompt — approve it.

```bash
SRC_CAL='Work' DST_CAL='Personal' DRY_RUN=1 VERBOSE=1 ~/bin/calsync
```

And the reverse direction:

```bash
SRC_CAL='Personal' DST_CAL='Work' DRY_RUN=1 VERBOSE=1 ~/bin/calsync
```

You should see a list of events each *would* create. When that looks right, run
them for real once:

```bash
SRC_CAL='Work' DST_CAL='Personal' ~/bin/calsync
```

```bash
SRC_CAL='Personal' DST_CAL='Work' ~/bin/calsync
```

Then run each a second time — both must report `0 created, 0 updated,
0 deleted`. If they churn instead, the date-comparison tolerance or the sync-key
derivation is wrong and needs fixing before scheduling anything.

To undo everything at any point, delete the `Busy` events by hand — or point it
at an empty source calendar and let it clean up its own copies.

### 4. Check the wrapper

`mirror.sh` runs the binary once per direction. It takes the two calendar titles
from `CAL_A` and `CAL_B`:

```bash
CAL_A='Work' CAL_B='Personal' DRY_RUN=1 ~/bin/calsync-mirror
```

Both directions run every time. If one fails the other still runs, and the
wrapper exits non-zero so the failure lands in `/tmp/calsync.err.log`.

### 5. Schedule it

The calendar titles live in the LaunchAgent's `EnvironmentVariables`, not in the
repository — so install the plist first, then set your own titles on the
installed copy:

```bash
mkdir -p ~/Library/LaunchAgents
cp com.weitzman.calsync.plist ~/Library/LaunchAgents/
```

```bash
P=~/Library/LaunchAgents/com.weitzman.calsync.plist
/usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:CAL_A Work" "$P"
/usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:CAL_B Personal" "$P"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:CAL_A_ID string <id-from-step-2>" "$P"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:CAL_B_ID string <id-from-step-2>" "$P"
```

The `_ID` lines are what actually bind the calendars; the titles are then only
labels for log readability.

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.weitzman.calsync.plist
```

Watch it work:

```bash
tail -f /tmp/calsync.log
```

To stop:

```bash
launchctl bootout gui/$(id -u)/com.weitzman.calsync
```

To reload after editing the plist, bootout then bootstrap again.

## Settings

All configured via `EnvironmentVariables` in the LaunchAgent.

`mirror.sh` takes the two calendar titles as `CAL_A` and `CAL_B` (and their
identifiers as `CAL_A_ID`/`CAL_B_ID`) and sets `SRC_CAL`/`DST_CAL` and
`SRC_CAL_ID`/`DST_CAL_ID` itself, once each way. Everything below is read by
the engine and can be set alongside them.

| Variable | Default | Meaning |
|---|---|---|
| `SRC_CAL` | `Calendar` | Source calendar title |
| `DST_CAL` | `Personal` | Destination calendar title |
| `SRC_CAL_ID` | — | Source calendar identifier; when set, the title is ignored. Prefer for anything scheduled |
| `DST_CAL_ID` | — | Likewise for the destination |
| `MIRROR_TITLE` | `Busy` | Title given to every copy |
| `HORIZON_DAYS` | `14` | How far ahead to look |
| `SKIP_DECLINED` | `1` | Skip meetings you've declined |
| `EXCLUDE_NOTES` | `created by Reclaim,app.reclaim.ai` | Comma-separated substrings; a source event whose notes contain any of them is never mirrored |
| `MAX_CREATES` | `60` | Abort without writing if one run would create more copies than this; `0` disables |
| `MAX_DELETES` | `60` | Same, for deletions; `0` disables |
| `ALLOW_EMPTY_SOURCE` | `0` | `1` to permit deleting every copy when the source reads empty |
| `SYNC_SCOPE` | — | Short tag isolating this pairing's copies when several sources feed one destination (`mirror.sh` sets `a2c`/`b2c` for `CAL_C`) |
| `DRY_RUN` | `0` | Print actions, write nothing |
| `VERBOSE` | `0` | Log every event |

### Other mirroring tools

`EXCLUDE_NOTES` exists because scheduling tools such as Reclaim.ai watch one
calendar and write their own blocks into the other. Those blocks carry no
`[sync:]` marker, so without the exclusion `calsync` treats them as genuine
source events and mirrors them back — and each run roughly doubles the set. Any
tool that copies events *into* a calendar `calsync` reads needs a matching entry
here.

`MAX_CREATES` is the backstop for the same class of failure. If copies ever stop
being recognised as copies — a `[sync:]` marker lost or rewritten by a server —
every run re-creates them. Above the limit nothing is committed and the run exits
non-zero.

### Staleness alarm

A broken mirror is silent: `launchd` keeps firing, every run errors into a log
nobody reads, and stale copies accumulate. So `mirror.sh` records the time of
the last fully successful run (in `~/.local/state/calsync/`), and once failures
have persisted past `STALE_AFTER_MINUTES` (default 60) it posts a macOS
notification, at most one per `ALERT_EVERY_MINUTES` (default 240). Set
`STALE_AFTER_MINUTES=0` to disable.

The first notification may need approving under **System Settings ▸
Notifications** (it arrives attributed to Script Editor). Two blind spots: it
watches the engine, not `launchd` — if the agent stops being scheduled at all,
nothing runs, so nothing alerts — and a cancellation that lands while the
mirror is down, whose event passes before repair, leaves a stale copy that the
past-preservation rule then keeps; clean those up by hand.

`MAX_DELETES` guards the destructive half. A source read that comes back short —
a failed fetch, a title that no longer matches — makes copies of events that
still exist look orphaned. A source that reads *entirely* empty is refused
outright unless `ALLOW_EMPTY_SOURCE=1`, since that is both what a broken read
looks like and how you deliberately clear the mirror.

## Notes and edge cases

- **Deletions.** A copy is removed when its source occurrence disappears for any
  reason: deleted, cancelled, declined, converted to all-day, or moved past the
  2-week horizon. The destination is scanned 2 days wider than the sync window
  so a copy that drifted just outside still gets cleaned up. Copies that have
  already ended are never deleted — past mirrored events stay as a record.
- **Recurring meetings** are mirrored per-occurrence. Editing a single
  occurrence in the source updates only that copy.
- **Rescheduling.** A key carries the occurrence's start time, so moving an
  event changes its key. A copy whose identifier still matches exactly one
  wanted occurrence is re-matched onto the new key and updated in place rather
  than deleted and re-created. Where a whole recurring series shares one
  identifier — Google-backed calendars do this, Exchange gives each occurrence
  its own `/RID=` — the stamp is the only discriminator, so a moved occurrence
  there is still a delete plus a create.
- **Declined meetings** are skipped, but only when the invitation names you
  individually. If you were invited via a distribution list, EventKit has no
  attendee record for you and cannot see the decline, so the event still
  mirrors. Delete it from the source instead.
- **Sub-second date drift** from CalDAV round-trips is ignored (1s tolerance),
  otherwise every run would rewrite every event.
- **No alarms** are set on copies, so you won't get doubled notifications.
- **Busy/free status** is carried over when the destination supports it.
- **Idle runs are free** — if nothing changed, no writes are committed, so the
  10-minute cadence doesn't hammer either server.
- **Sleep.** `launchd` fires a missed `StartInterval` once on wake, not once per
  interval missed.

## If TCC denies access

Should a `launchd` run ever report no calendar access while running it by hand
works, the grant is not reaching the binary. In order of escalation: run it once
from Terminal and approve the prompt; check `~/bin/calsync` under **System
Settings ▸ Privacy & Security ▸ Calendars**; failing that, add it under **Full
Disk Access**.

Rebuilding re-signs the binary, which can invalidate the grant — if a run starts
failing right after a rebuild, run it from Terminal once to re-approve.

## Routing through a Shortcut instead

An earlier version of this ran the binary from a Shortcut, with `launchd` firing
`shortcuts run <name>` on the interval. The Shortcut held the Calendars
permission and the shell script it launched inherited that attribution, which
sidestepped the question of whether a bare binary could get its own grant.

It works, but it is strictly more moving parts, the Shortcut is not
version-controlled, and it puts your calendar titles in a place no backup
covers. Only worth reaching for if the direct route cannot get a TCC grant on
your machine.
