#!/bin/bash
# Runs calsync once in each direction between two calendars.
#
# Exists because launchd runs a single program per job, and a two-way mirror is
# two invocations. Calendar titles arrive in the environment — from the
# LaunchAgent's EnvironmentVariables — so nothing personal lives in this file or
# in the repository.
#
# Required:  CAL_A, CAL_B     the two calendar titles
# Optional:  CALSYNC_BIN      path to the binary (default ~/bin/calsync)
#            plus any calsync setting: MIRROR_TITLE, HORIZON_DAYS, EXCLUDE_NOTES…

set -u

: "${CAL_A:?CAL_A must be set to a calendar title}"
: "${CAL_B:?CAL_B must be set to a calendar title}"

BIN="${CALSYNC_BIN:-$HOME/bin/calsync}"

if [ ! -x "$BIN" ]; then
  echo "calsync not found or not executable at $BIN" >&2
  exit 1
fi

rc=0

# Each direction runs even if the other fails, so one bad server doesn't stall
# the whole mirror. A non-zero exit surfaces in the agent's StandardErrorPath.
SRC_CAL="$CAL_A" DST_CAL="$CAL_B" "$BIN" || rc=1
SRC_CAL="$CAL_B" DST_CAL="$CAL_A" "$BIN" || rc=1

exit $rc
