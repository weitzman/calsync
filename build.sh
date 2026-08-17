#!/bin/bash
# Build calsync and install it to ~/bin/calsync.
#
# The Info.plist is embedded into the binary's __TEXT,__info_plist section.
# Without it, a bare command-line tool that asks EventKit for access is killed
# by TCC instead of showing a permission prompt. The ad-hoc signature gives the
# binary a stable identity so macOS remembers the permission across rebuilds
# of unrelated files (rebuilding calsync itself will re-prompt).

set -euo pipefail

cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode command line tools:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

DEST="$HOME/bin"
mkdir -p "$DEST"

echo "Compiling..."
# swiftc only accepts top-level code in a file called main.swift.
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
cp calsync.swift "$BUILD_DIR/main.swift"

swiftc -O "$BUILD_DIR/main.swift" -o "$DEST/calsync" \
  -framework EventKit -framework Foundation \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PWD/Info.plist"

echo "Signing (ad-hoc)..."
codesign --force --sign - --identifier com.weitzman.calsync "$DEST/calsync"

# The two-direction wrapper the LaunchAgent invokes.
install -m 755 mirror.sh "$DEST/calsync-mirror"

echo
echo "Installed: $DEST/calsync"
echo "Installed: $DEST/calsync-mirror"
echo
echo "Next: run it once from Terminal to trigger the Calendars permission prompt:"
echo "  SRC_CAL='Work' DST_CAL='Personal' DRY_RUN=1 VERBOSE=1 $DEST/calsync"
