#!/usr/bin/env bash
#
# Build the macOS app for this fork: GhosttyKit through zig, then the app
# through xcodebuild. Works without `sudo xcode-select`, because zig's own
# xcodebuild step strips DEVELOPER_DIR from the environment.
#
# Usage:
#   scripts/fork-build.sh [Debug|ReleaseLocal|Release]   (default ReleaseLocal)
#
# Output: macos/build/<Configuration>/Ghostty.app
#
# GhosttyKit is built for this Mac only; set XCFRAMEWORK_TARGET=universal for
# an Intel + Apple Silicon build.

set -euo pipefail

CONFIGURATION="${1:-ReleaseLocal}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
	export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

case "$CONFIGURATION" in
Debug) OPTIMIZE="Debug" ;;
*) OPTIMIZE="ReleaseFast" ;;
esac

cd "$ROOT"
XCFRAMEWORK_TARGET="${XCFRAMEWORK_TARGET:-native}"
zig build -Doptimize="$OPTIMIZE" -Demit-macos-app=false -Dxcframework-target="$XCFRAMEWORK_TARGET"

# A native GhosttyKit has only this Mac's slice, so the app must match.
ARCH_ARGS=()
if [ "$XCFRAMEWORK_TARGET" = native ]; then
	ARCH_ARGS=(ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES)
fi

cd "$ROOT/macos"
LOG="$(mktemp -t ghostty-xcodebuild)"
if ! xcodebuild -target Ghostty -configuration "$CONFIGURATION" "${ARCH_ARGS[@]}" >"$LOG" 2>&1; then
	grep -E "error:" "$LOG" || tail -40 "$LOG"
	echo "xcodebuild failed; full log: $LOG" >&2
	exit 1
fi
rm -f "$LOG"

echo "Built: $ROOT/macos/build/$CONFIGURATION/Ghostty.app"
