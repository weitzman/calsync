#!/bin/bash
# Runs calsync once in each direction between two calendars.
#
# Exists because launchd runs a single program per job, and a two-way mirror is
# two invocations. Calendar titles arrive in the environment — from the
# LaunchAgent's EnvironmentVariables — so nothing personal lives in this file or
# in the repository.
#
# Required:  CAL_A, CAL_B         the two calendar titles
# Optional:  CAL_C, CAL_C_ID      a third calendar that A and B are mirrored
#                                 INTO, one-way; nothing syncs back out of it
# Optional:  CAL_A_ID, CAL_B_ID   calendar identifiers; when set, the matching
#                                 title is ignored. Prefer these: titles are
#                                 neither stable (Exchange reverts renames of
#                                 its default calendar) nor unique.
#            CALSYNC_BIN          path to the binary (default ~/bin/calsync)
#            STALE_AFTER_MINUTES  post a macOS notification when runs have been
#                                 failing this long (default 60; 0 disables)
#            ALERT_EVERY_MINUTES  at most one notification per this many
#                                 minutes (default 240)
#            plus any calsync setting: MIRROR_TITLE, HORIZON_DAYS, EXCLUDE_NOTES…

set -u

: "${CAL_A:?CAL_A must be set to a calendar title}"
: "${CAL_B:?CAL_B must be set to a calendar title}"
CAL_A_ID="${CAL_A_ID:-}"
CAL_B_ID="${CAL_B_ID:-}"
CAL_C="${CAL_C:-}"
CAL_C_ID="${CAL_C_ID:-}"

BIN="${CALSYNC_BIN:-$HOME/bin/calsync}"

if [ ! -x "$BIN" ]; then
  echo "calsync not found or not executable at $BIN" >&2
  exit 1
fi

rc=0

# One header per wrapper run so the log reads as blocks, not a wall of lines.
echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="

# Runs one pairing. Exit 2 from calsync means a calendar is unavailable — an
# account deliberately toggled off in Calendar, not a malfunction — so that
# pairing is PAUSED: noted in the log, but it neither fails the run nor wakes
# the staleness alarm. It resumes by itself once the calendar is back. Any
# other non-zero exit is a real failure. Each pairing runs even if another
# fails, so one bad server doesn't stall the whole mirror.
sync_pair() {
  local label=$1; shift
  env "$@" "$BIN"
  case $? in
    0) ;;
    2) echo "calsync: $label paused — calendar unavailable" ;;
    *) rc=1 ;;
  esac
}

sync_pair "A->B" SRC_CAL="$CAL_A" SRC_CAL_ID="$CAL_A_ID" DST_CAL="$CAL_B" DST_CAL_ID="$CAL_B_ID"
sync_pair "B->A" SRC_CAL="$CAL_B" SRC_CAL_ID="$CAL_B_ID" DST_CAL="$CAL_A" DST_CAL_ID="$CAL_A_ID"

# Optional third calendar: A and B are additionally mirrored ONE-WAY into C.
# Both pairings share C as a destination, so each carries its own SYNC_SCOPE —
# without one, each run would delete the other pairing's copies as orphans.
# Nothing is ever read out of C. The scope tags are baked into stored markers;
# never change them once copies exist.
if [ -n "$CAL_C$CAL_C_ID" ]; then
  sync_pair "A->C" SRC_CAL="$CAL_A" SRC_CAL_ID="$CAL_A_ID" DST_CAL="$CAL_C" DST_CAL_ID="$CAL_C_ID" SYNC_SCOPE=a2c
  sync_pair "B->C" SRC_CAL="$CAL_B" SRC_CAL_ID="$CAL_B_ID" DST_CAL="$CAL_C" DST_CAL_ID="$CAL_C_ID" SYNC_SCOPE=b2c
fi

# ---- staleness alarm -------------------------------------------------------
# A broken mirror is silent: launchd keeps firing, every run errors into a log
# nobody reads, and stale copies accumulate (this happened — an Exchange title
# revert killed every run for two days). So track the last fully successful
# run, and when failures have persisted past STALE_AFTER_MINUTES, say so with
# an alert dialog offering to open the log. Throttled: a dead mirror on a
# 10-minute cadence should alert, not nag.
#
# This watches the engine, not launchd itself — if the agent stops being
# scheduled at all, nothing runs, so nothing alerts.

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/calsync"
mkdir -p "$STATE_DIR"

STALE_AFTER_MINUTES="${STALE_AFTER_MINUTES:-60}"
ALERT_EVERY_MINUTES="${ALERT_EVERY_MINUTES:-240}"

now=$(date +%s)

if [ "$rc" -eq 0 ]; then
  echo "$now" > "$STATE_DIR/last-success"
elif [ "$STALE_AFTER_MINUTES" -gt 0 ]; then
  last_ok=$(cat "$STATE_DIR/last-success" 2>/dev/null || echo 0)
  last_alert=$(cat "$STATE_DIR/last-alert" 2>/dev/null || echo 0)
  stale_min=$(( (now - last_ok) / 60 ))
  if [ "$stale_min" -ge "$STALE_AFTER_MINUTES" ] \
     && [ $(( (now - last_alert) / 60 )) -ge "$ALERT_EVERY_MINUTES" ]; then
    if [ "$last_ok" -eq 0 ]; then
      age_text="never succeeded on this Mac"
    elif [ "$stale_min" -ge 120 ]; then
      age_text="failing for $(( stale_min / 60 )) hours"
    else
      age_text="failing for $stale_min minutes"
    fi
    # An alert dialog rather than a banner: banners posted from a script are
    # not clickable, a dialog can offer "Open log". It gives up after 10
    # minutes so a hung dialog never wedges the agent, and the throttle stamp
    # is written first so a waiting dialog can't pile up siblings.
    echo "$now" > "$STATE_DIR/last-alert"
    afplay /System/Library/Sounds/Basso.aiff 2>/dev/null
    osascript >/dev/null 2>&1 <<OSA
set r to display alert "calsync stale" message "Sync has been $age_text." buttons {"Dismiss", "Open log"} default button "Open log" giving up after 600
if button returned of r is "Open log" then do shell script "open /tmp/calsync.err.log"
OSA
  fi
fi

exit $rc
