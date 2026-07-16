#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/OPTCG Alt Art Switcher.app}"
ZIP="${2:-}"
EXECUTABLE="$APP/Contents/MacOS/OPTCGAltArtSwitcher"
PLIST="$APP/Contents/Info.plist"

[[ -d "$APP" ]] || { echo "App bundle not found: $APP" >&2; exit 1; }
[[ -x "$EXECUTABLE" ]] || { echo "App executable not found" >&2; exit 1; }
[[ -f "$APP/Contents/Resources/LICENSE.txt" ]] || { echo "Bundled GPLv3 license not found" >&2; exit 1; }

ARCHS="$(lipo -archs "$EXECUTABLE")"
[[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]] || {
    echo "Expected a universal arm64 + x86_64 binary; found: $ARCHS" >&2
    exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" == "13.0" ]] || {
    echo "Expected macOS 13.0 minimum version" >&2
    exit 1
}
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ -n "$ZIP" ]]; then
    [[ -f "$ZIP" ]] || { echo "Release archive not found: $ZIP" >&2; exit 1; }
    unzip -t "$ZIP" >/dev/null
fi

echo "Release verification passed: $APP"
