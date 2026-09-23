// calsync — mirrors timed events from one Mac calendar into another.
//
// Run it twice with SRC_CAL and DST_CAL swapped for a two-way mirror; each
// direction ignores the copies made by the other (see the marker note below).
//
// Behaviour:
//   * Looks HORIZON_DAYS (default 14) into the future, starting now.
//   * Skips all-day events, including timed events spanning whole days
//     (Google's "Out of office" is midnight-to-midnight, not flagged all-day).
//   * Optionally skips events you've declined.
//   * Creates a copy in the destination calendar titled "Busy" (no location,
//     no attendees, no alarms, no notes other than a hidden sync marker).
//   * Each copy carries "[sync:<key>]" in its notes. The key identifies the exact
//     source occurrence (external id + occurrence date), so recurring meetings are
//     handled per-occurrence.
//   * On every run it reconciles: moved events are updated, duplicates are pruned,
//     and copies whose source no longer exists are DELETED.
//
// Nothing is ever written to the source calendar.
//
// Env vars:
//   SRC_CAL       source calendar title            (default "Calendar")
//   DST_CAL       destination calendar title       (default "Personal")
//   SRC_CAL_ID    source calendar identifier; when set, the title is ignored.
//                 Identifiers survive renames and duplicate titles — prefer
//                 them for anything scheduled. Run with a wrong title to list
//                 every calendar with its id.
//   DST_CAL_ID    likewise for the destination
//   MIRROR_TITLE  title used for copies            (default "Busy")
//   HORIZON_DAYS  days to look ahead               (default 14)
//   SKIP_DECLINED 1 to skip events you declined    (default 1)
//   EXCLUDE_NOTES comma-separated substrings; source events whose notes contain
//                 any of them are never mirrored
//                 (default "created by Reclaim,app.reclaim.ai")
//   MAX_CREATES   abort without writing if one run would create more than this
//                 many copies; 0 disables            (default 60)
//   MAX_DELETES   likewise for deletions             (default 60)
//   ALLOW_EMPTY_SOURCE
//                 1 to permit deleting every copy when the source reads empty
//                 (the "clear the mirror" workflow)  (default 0)
//   SYNC_SCOPE    short tag isolating this pairing's copies when several
//                 sources feed one destination; markers become
//                 "[sync:<scope>|<key>]"             (default none)
//   DRY_RUN       1 to print actions without writing
//   VERBOSE       1 for per-event logging

import Foundation
import EventKit

// ---------------------------------------------------------------- configuration

let env = ProcessInfo.processInfo.environment
func envStr(_ k: String, _ d: String) -> String { env[k].flatMap { $0.isEmpty ? nil : $0 } ?? d }
func envInt(_ k: String, _ d: Int) -> Int { Int(envStr(k, "")) ?? d }
func envBool(_ k: String, _ d: Bool) -> Bool {
    guard let v = env[k]?.lowercased(), !v.isEmpty else { return d }
    return ["1", "true", "yes", "on"].contains(v)
}

let SRC_CAL       = envStr("SRC_CAL", "Calendar")
let DST_CAL       = envStr("DST_CAL", "Personal")
// When set, these override the titles entirely (see resolveCalendar).
let SRC_CAL_ID    = envStr("SRC_CAL_ID", "")
let DST_CAL_ID    = envStr("DST_CAL_ID", "")
let MIRROR_TITLE  = envStr("MIRROR_TITLE", "Busy")
let HORIZON_DAYS  = max(1, envInt("HORIZON_DAYS", 14))
let SKIP_DECLINED = envBool("SKIP_DECLINED", true)

// When several source calendars feed ONE destination, each pairing must only
// manage its own copies — otherwise every run sees the other pairing's copies
// as orphans and deletes them. A scope prefixes the stored marker
// ("[sync:<scope>|<key>]") and the destination scan ignores copies from any
// other scope (or, when no scope is set, any scoped copy). Single-destination
// setups need none.
let SYNC_SCOPE    = envStr("SYNC_SCOPE", "")
let DRY_RUN       = envBool("DRY_RUN", false)
let VERBOSE       = envBool("VERBOSE", false)

// Comma-separated substrings; a source event whose notes contain any of them is
// never mirrored. Defaults target Reclaim.ai, which writes its own blocks into
// the work calendar in response to events in the destination calendar. Without
// this, the two tools form a feedback loop: we mirror work -> personal, Reclaim
// mirrors personal -> work, and each run doubles the set. Set to an empty string
// to disable.
// Runaway guard. A mirror loop shows up as an ever-growing number of creations:
// if copies stop being recognised as copies (marker lost or rewritten by the
// server), every run re-creates them. Above this many creations in one run,
// nothing is committed. 0 disables the check.
let MAX_CREATES   = envInt("MAX_CREATES", 60)

// The same guard in the other direction. Deletions are the destructive half:
// a source that reads empty or short — a failed fetch, a mis-targeted title —
// makes every copy look orphaned. 0 disables.
let MAX_DELETES   = envInt("MAX_DELETES", 60)

// Permits the documented "point it at an empty source to clean up" workflow,
// which is otherwise refused for the reason above.
let ALLOW_EMPTY_SOURCE = envBool("ALLOW_EMPTY_SOURCE", false)

let EXCLUDE_NOTES: [String] = envStr("EXCLUDE_NOTES", "created by Reclaim,app.reclaim.ai")
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    .filter { !$0.isEmpty }

let MARKER_PREFIX = "[sync:"
let MARKER_SUFFIX = "]"

// ---------------------------------------------------------------- logging

let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ msg: String) {
    print("\(stamp.string(from: Date())) \(msg)")
    fflush(stdout)
}
func vlog(_ msg: String) { if VERBOSE { log(msg) } }
func die(_ msg: String) -> Never {
    FileHandle.standardError.write("\(stamp.string(from: Date())) ERROR: \(msg)\n".data(using: .utf8)!)
    exit(1)
}

// ---------------------------------------------------------------- authorization

let store = EKEventStore()

func requestAccess() -> Bool {
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    let handler: (Bool, Error?) -> Void = { ok, err in
        granted = ok
        if let err = err { log("auth error: \(err.localizedDescription)") }
        sem.signal()
    }
    if #available(macOS 14.0, *) {
        store.requestFullAccessToEvents(completion: handler)
    } else {
        store.requestAccess(to: .event, completion: handler)
    }
    // Pump the run loop while waiting so the TCC prompt can appear.
    while sem.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    return granted
}

guard requestAccess() else {
    die("no calendar access. Grant it in System Settings > Privacy & Security > Calendars, "
        + "then run this binary once from Terminal.")
}

// ---------------------------------------------------------------- calendars

let allCalendars = store.calendars(for: .event)

func findCalendar(_ title: String) -> EKCalendar? {
    if let exact = allCalendars.first(where: { $0.title == title }) { return exact }
    return allCalendars.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
}

// Titles are neither stable nor unique: Exchange reverts renames of its default
// calendar, and two accounts can each have a "Calendar". An identifier survives
// both, so when one is given it is the only thing consulted — a title match is
// not an acceptable fallback for a stale id, because with duplicate titles it
// could silently bind the wrong calendar, and an empty or wrong source is how
// every copy gets deleted. Identifiers do die with an account remove/re-add;
// the error prints the current ids for re-pinning.
func availableList() -> String {
    allCalendars.map { "\"\($0.title)\" (\($0.source.title), id \($0.calendarIdentifier))" }
        .joined(separator: ", ")
}

func resolveCalendar(id: String, title: String, role: String) -> EKCalendar {
    if !id.isEmpty {
        guard let c = allCalendars.first(where: { $0.calendarIdentifier == id }) else {
            die("\(role) calendar id \(id) not found — the account may have been removed "
                + "and re-added, which changes identifiers. Available: " + availableList())
        }
        return c
    }
    guard let c = findCalendar(title) else {
        die("\(role) calendar \"\(title)\" not found. Available: " + availableList())
    }
    return c
}

let source = resolveCalendar(id: SRC_CAL_ID, title: SRC_CAL, role: "source")
let dest   = resolveCalendar(id: DST_CAL_ID, title: DST_CAL, role: "destination")
guard source.calendarIdentifier != dest.calendarIdentifier else {
    die("source and destination are the same calendar")
}
guard dest.allowsContentModifications else {
    die("destination calendar \"\(dest.title)\" is read-only")
}

// ---------------------------------------------------------------- window

let windowStart = Date()
let windowEnd   = Calendar.current.date(byAdding: .day, value: HORIZON_DAYS, to: windowStart)!
// Scan the destination slightly wider so a copy that drifted just outside the
// horizon is still reachable for cleanup.
let scanStart = windowStart.addingTimeInterval(-2 * 24 * 3600)
let scanEnd   = windowEnd.addingTimeInterval(2 * 24 * 3600)

// ---------------------------------------------------------------- keys & markers

// The occurrence stamp is written in hex behind a "t" so it never looks like a
// phone number. A bare 10-digit epoch (e.g. "@1787076000") is picked up by the
// macOS data detectors and rendered as a tappable phone link in Calendar.
func occurrenceToken(_ seconds: Int) -> String { "t" + String(seconds, radix: 16) }

func syncKey(for event: EKEvent) -> String {
    let base = event.calendarItemExternalIdentifier
        ?? event.eventIdentifier
        ?? "\(event.title ?? "untitled")"
    let occurrence = event.occurrenceDate ?? event.startDate ?? Date.distantPast
    // Sanitize: the key lives inside "[sync:...]" so it must not contain "]".
    let safeBase = base.replacingOccurrences(of: "]", with: "_")
                       .replacingOccurrences(of: "[", with: "_")
    return "\(safeBase)@\(occurrenceToken(Int(occurrence.timeIntervalSince1970)))"
}

// Markers written before the hex change carry a bare decimal epoch. Rewriting
// them as-read means an existing copy is still recognised as the same copy, so
// it gets a cheap in-place update instead of being deleted and re-created.
func normalizeKey(_ key: String) -> String {
    guard let at = key.lastIndex(of: "@") else { return key }
    let suffix = key[key.index(after: at)...]
    guard !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber }), let seconds = Int(suffix)
    else { return key }
    return String(key[..<at]) + "@" + occurrenceToken(seconds)
}

func extractKey(fromNotes notes: String?) -> String? {
    guard let notes = notes,
          let lo = notes.range(of: MARKER_PREFIX),
          let hi = notes.range(of: MARKER_SUFFIX, range: lo.upperBound..<notes.endIndex)
    else { return nil }
    let key = String(notes[lo.upperBound..<hi.lowerBound])
    return key.isEmpty ? nil : key
}

func marker(_ key: String) -> String { "\(MARKER_PREFIX)\(key)\(MARKER_SUFFIX)" }

// The form a key takes inside a stored marker: scope-prefixed when scoped.
func storedKey(_ key: String) -> String { SYNC_SCOPE.isEmpty ? key : "\(SYNC_SCOPE)|\(key)" }

// The key, if a stored marker belongs to this run's scope; nil for another
// pairing's copy, which must be left alone.
func ownKey(fromStored stored: String) -> String? {
    if let bar = stored.firstIndex(of: "|") {
        guard String(stored[..<bar]) == SYNC_SCOPE else { return nil }
        return String(stored[stored.index(after: bar)...])
    }
    return SYNC_SCOPE.isEmpty ? stored : nil
}

// The part of a key in front of its occurrence stamp. Identifiers can contain
// "@" (Google-backed calendars use "…@google.com"), so split at the last one,
// and only when what follows really is a stamp.
func baseOf(_ key: String) -> String {
    guard let at = key.lastIndex(of: "@") else { return key }
    let suffix = key[key.index(after: at)...]
    guard suffix.first == "t", suffix.count > 1,
          suffix.dropFirst().allSatisfy({ $0.isHexDigit })
    else { return key }
    return String(key[..<at])
}

func availabilityMask(_ a: EKEventAvailability) -> EKCalendarEventAvailabilityMask {
    switch a {
    case .busy:        return .busy
    case .free:        return .free
    case .tentative:   return .tentative
    case .unavailable: return .unavailable
    default:           return []
    }
}

// What a copy's busy/free status should be: the source's, when the destination
// supports it, otherwise busy, otherwise whatever the copy already has.
func desiredAvailability(for src: EKEvent, fallback: EKEventAvailability) -> EKEventAvailability {
    let mask = availabilityMask(src.availability)
    if !mask.isEmpty && dest.supportedEventAvailabilities.contains(mask) { return src.availability }
    return dest.supportedEventAvailabilities.contains(.busy) ? .busy : fallback
}

// Dates from CalDAV round-trips can wobble by sub-second amounts.
func sameInstant(_ a: Date?, _ b: Date?) -> Bool {
    guard let a = a, let b = b else { return a == nil && b == nil }
    return abs(a.timeIntervalSince(b)) < 1.0
}

// ---------------------------------------------------------------- read source

let sourcePredicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [source])

// A source event authored by another mirroring tool, identified by its notes.
func isForeignMirror(_ ev: EKEvent) -> Bool {
    guard !EXCLUDE_NOTES.isEmpty else { return false }
    guard let notes = ev.notes?.lowercased(), !notes.isEmpty else { return false }
    return EXCLUDE_NOTES.contains { notes.contains($0) }
}

var excluded = 0

let sourceEvents: [EKEvent] = store.events(matching: sourcePredicate).filter { ev in
    if ev.isAllDay { return false }
    guard let start = ev.startDate, let end = ev.endDate else { return false }
    // Google's "Out of office" blocks are timed midnight-to-midnight events,
    // not flagged all-day. Treat anything spanning whole local days the same.
    if start == Calendar.current.startOfDay(for: start),
       end == Calendar.current.startOfDay(for: end) { return false }
    if ev.status == .canceled { return false }
    if SKIP_DECLINED, let me = ev.attendees?.first(where: { $0.isCurrentUser }),
       me.participantStatus == .declined { return false }
    // Defensive: never mirror something that is itself a mirror.
    if extractKey(fromNotes: ev.notes) != nil { return false }
    // Likewise for mirrors written by another tool, which carry no marker of ours.
    if isForeignMirror(ev) {
        excluded += 1
        vlog("exclude \(stamp.string(from: ev.startDate))  \(ev.title ?? "untitled")")
        return false
    }
    return true
}

var wanted: [String: EKEvent] = [:]
for ev in sourceEvents {
    let k = syncKey(for: ev)
    if wanted[k] == nil { wanted[k] = ev }
}

log("source \"\(SRC_CAL)\": \(wanted.count) timed event(s) in the next \(HORIZON_DAYS) day(s)"
    + (excluded > 0 ? ", \(excluded) foreign mirror(s) excluded" : ""))

// ---------------------------------------------------------------- read destination

let destPredicate = store.predicateForEvents(withStart: scanStart, end: scanEnd, calendars: [dest])

// Reschedule a one-off meeting and its occurrence stamp moves with it, so the
// key changes and the existing copy would look orphaned: deleted, then a fresh
// one created. Re-map those copies onto the new key instead, turning the move
// into an in-place update. Only a base that identifies exactly one wanted
// occurrence is eligible — every occurrence of a recurring series shares one
// base, and there the stamp is the only thing telling them apart.
var wantedByBase: [String: String] = [:]
var ambiguousBases: Set<String> = []
for key in wanted.keys {
    let b = baseOf(key)
    if wantedByBase[b] != nil { ambiguousBases.insert(b) } else { wantedByBase[b] = key }
}
for b in ambiguousBases { wantedByBase.removeValue(forKey: b) }

var existing: [String: [EKEvent]] = [:]
var rekeyed = 0
for ev in store.events(matching: destPredicate) {
    guard let raw = extractKey(fromNotes: ev.notes) else { continue }  // leave hand-made events alone
    guard let own = ownKey(fromStored: raw) else { continue }          // another pairing's copy
    var k = normalizeKey(own)
    if wanted[k] == nil, let moved = wantedByBase[baseOf(k)], moved != k {
        k = moved
        rekeyed += 1
    }
    existing[k, default: []].append(ev)
}

let managedCount = existing.values.reduce(0) { $0 + $1.count }
log("destination \"\(DST_CAL)\": \(managedCount) managed copy(ies) in range"
    + (rekeyed > 0 ? ", \(rekeyed) rematched after a source move" : ""))

// An empty source with copies still in the destination is indistinguishable
// from a failed or mis-targeted source read, and the delete pass below would
// remove every one of them. Clearing the mirror this way is a documented
// workflow, so it stays available — but only when asked for explicitly.
if wanted.isEmpty && managedCount > 0 && !ALLOW_EMPTY_SOURCE {
    let why = "source \"\(SRC_CAL)\" returned no events while the destination holds "
        + "\(managedCount) managed copy(ies). Refusing to delete them all. Set "
        + "ALLOW_EMPTY_SOURCE=1 if you really are clearing the mirror."
    if DRY_RUN { log("WARNING: \(why)") } else { die(why) }
}

// ---------------------------------------------------------------- reconcile

var created = 0, updated = 0, deleted = 0, unchanged = 0
var pendingWrites = 0
var failures = 0

func save(_ ev: EKEvent, _ what: String) {
    if DRY_RUN { return }
    do {
        try store.save(ev, span: .thisEvent, commit: false)
        pendingWrites += 1
    } catch {
        failures += 1
        log("failed to \(what): \(error.localizedDescription)")
    }
}

func remove(_ ev: EKEvent, _ what: String) {
    if DRY_RUN { return }
    do {
        try store.remove(ev, span: .thisEvent, commit: false)
        pendingWrites += 1
    } catch {
        failures += 1
        log("failed to \(what): \(error.localizedDescription)")
    }
}

// 1. Create or update a copy for every wanted source occurrence.
for (key, src) in wanted {
    let copies = existing[key] ?? []

    if copies.isEmpty {
        let copy = EKEvent(eventStore: store)
        copy.calendar   = dest
        copy.title      = MIRROR_TITLE
        copy.startDate  = src.startDate
        copy.endDate    = src.endDate
        copy.isAllDay   = false
        copy.notes      = marker(storedKey(key))
        copy.alarms     = nil
        copy.availability = desiredAvailability(for: src, fallback: copy.availability)
        vlog("create  \(stamp.string(from: src.startDate)) -> \(MIRROR_TITLE)")
        save(copy, "create copy for \(key)")
        created += 1
        continue
    }

    // Keep the first copy, delete any duplicates.
    let keeper = copies[0]
    for dup in copies.dropFirst() {
        vlog("dedupe  \(stamp.string(from: dup.startDate ?? Date()))")
        remove(dup, "delete duplicate for \(key)")
        deleted += 1
    }

    var dirty = false
    if !sameInstant(keeper.startDate, src.startDate) { keeper.startDate = src.startDate; dirty = true }
    if !sameInstant(keeper.endDate, src.endDate)     { keeper.endDate   = src.endDate;   dirty = true }
    if keeper.title != MIRROR_TITLE                  { keeper.title     = MIRROR_TITLE;  dirty = true }
    if keeper.isAllDay                               { keeper.isAllDay  = false;         dirty = true }
    if keeper.notes != marker(storedKey(key))        { keeper.notes     = marker(storedKey(key)); dirty = true }
    let wantAvailability = desiredAvailability(for: src, fallback: keeper.availability)
    if keeper.availability != wantAvailability { keeper.availability = wantAvailability; dirty = true }

    if dirty {
        vlog("update  \(stamp.string(from: src.startDate))")
        save(keeper, "update copy for \(key)")
        updated += 1
    } else {
        unchanged += 1
    }
}

// 2. Delete copies whose source occurrence is gone (deleted, moved out of the
//    horizon, turned all-day, cancelled, or declined).
//    Copies that already ended are left alone — they're history, not drift.
for (key, copies) in existing where wanted[key] == nil {
    for orphan in copies {
        guard let ends = orphan.endDate, ends > windowStart else {
            vlog("keep    \(stamp.string(from: orphan.startDate ?? Date()))  (already past)")
            continue
        }
        vlog("delete  \(stamp.string(from: orphan.startDate ?? Date()))  (source gone)")
        remove(orphan, "delete orphan \(key)")
        deleted += 1
    }
}

// ---------------------------------------------------------------- commit

if DRY_RUN {
    log("DRY RUN — would create \(created), update \(updated), delete \(deleted); \(unchanged) unchanged")
    if MAX_CREATES > 0 && created > MAX_CREATES {
        log("WARNING: \(created) creations exceeds MAX_CREATES=\(MAX_CREATES); a real run would abort.")
    }
    if MAX_DELETES > 0 && deleted > MAX_DELETES {
        log("WARNING: \(deleted) deletions exceeds MAX_DELETES=\(MAX_DELETES); a real run would abort.")
    }
    exit(0)
}

if MAX_CREATES > 0 && created > MAX_CREATES {
    store.reset()   // discard every uncommitted change
    die("aborting: \(created) creation(s) exceeds MAX_CREATES=\(MAX_CREATES). Nothing was written. "
        + "This usually means existing copies are no longer recognised as copies — a lost or rewritten "
        + "[sync:] marker — which makes the mirror loop. Investigate before running again.")
}

if MAX_DELETES > 0 && deleted > MAX_DELETES {
    store.reset()
    die("aborting: \(deleted) deletion(s) exceeds MAX_DELETES=\(MAX_DELETES). Nothing was written. "
        + "This usually means the source read came back short, so copies of events that still exist "
        + "look orphaned. Investigate before running again.")
}

if pendingWrites > 0 {
    do {
        try store.commit()
    } catch {
        die("commit failed: \(error.localizedDescription)")
    }
}

log("created \(created), updated \(updated), deleted \(deleted), unchanged \(unchanged)"
    + (failures > 0 ? ", \(failures) failure(s)" : ""))
exit(failures > 0 ? 1 : 0)
