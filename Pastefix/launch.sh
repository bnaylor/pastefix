#!/bin/sh
# Build and launch the Pastefix menu-bar app (Debug).
# Works from any directory: paths are resolved relative to this script.
#
#   ./launch.sh          build + launch
#   ./launch.sh --run     same
#   ./launch.sh --path    just print the .app path, don't build or launch
set -eu

# Directory this script lives in (contains Pastefix.xcodeproj).
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJECT="$SCRIPT_DIR/Pastefix.xcodeproj"
SCHEME="Pastefix"
CONFIG="Debug"
DEST="platform=macOS,arch=arm64"

app_path() {
    # Ask xcodebuild where it puts the product for THIS config/destination.
    # (Querying without matching -configuration returns the Release path — the
    # trap that made ./build/Release look missing.)
    xcodebuild -showBuildSettings \
        -project "$PROJECT" -scheme "$SCHEME" \
        -configuration "$CONFIG" -destination "$DEST" 2>/dev/null \
    | awk -F' = ' '
        / TARGET_BUILD_DIR / { dir = $2 }
        / WRAPPER_NAME /      { name = $2 }
        END { if (dir && name) print dir "/" name }'
}

if [ "${1:-}" = "--path" ]; then
    app_path
    exit 0
fi

echo "Building $SCHEME ($CONFIG)…"
xcodebuild build \
    -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIG" -destination "$DEST" -quiet

APP=$(app_path)
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "error: could not locate built app (got: '${APP:-}')" >&2
    exit 1
fi

echo "Launching: $APP"
open "$APP"
echo "Look for the clipboard icon in the menu bar (no Dock icon)."
