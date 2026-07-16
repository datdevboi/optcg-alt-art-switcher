#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── 1. Compile ────────────────────────────────────────────────────────────────
# Set ARCHS="arm64 x86_64" for a universal release. Local builds default to the
# current machine's architecture so they work with Command Line Tools alone.
ARCHS="${ARCHS:-$(uname -m)}"
VERSION="${VERSION:-1.0.0}"
VERSION="${VERSION#v}"
BUILD_ROOT="$ROOT/.build/release-architectures"
BINARIES=()

rm -rf "$BUILD_ROOT"
for ARCH in ${(z)ARCHS}; do
    echo "▶ Building $ARCH release binary…"
    ARCH_BUILD="$BUILD_ROOT/$ARCH"
    swift build -c release --triple "$ARCH-apple-macosx13.0" --scratch-path "$ARCH_BUILD"
    BINARIES+=("$ARCH_BUILD/$ARCH-apple-macosx/release/OPTCGAltArtSwitcher")
done

if (( ${#BINARIES[@]} == 1 )); then
    APP_BINARY="${BINARIES[1]}"
else
    echo "▶ Combining universal binary…"
    APP_BINARY="$BUILD_ROOT/OPTCGAltArtSwitcher"
    lipo -create "${BINARIES[@]}" -output "$APP_BINARY"
fi

# ── 2. Assemble .app bundle ───────────────────────────────────────────────────
APP="$ROOT/dist/OPTCG Alt Art Switcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$APP_BINARY" "$APP/Contents/MacOS/OPTCGAltArtSwitcher"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

# ── 3. Generate .icns from bundled PNG ────────────────────────────────────────
SOURCE_ICON="$ROOT/scripts/AppIcon.png"
ICONSET_DIR="$ROOT/dist/AppIcon.iconset"
ICNS_PATH="$APP/Contents/Resources/AppIcon.icns"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# Normalize source to a clean sRGB PNG so sips writes proper PNG iconset files
NORMALIZED_ICON="$ROOT/dist/.AppIconNormalized.png"
sips --setProperty format png "$SOURCE_ICON" --out "$NORMALIZED_ICON" > /dev/null

echo "▶ Generating icon set…"
for SIZE in 16 32 128 256 512; do
    sips -z $SIZE $SIZE "$NORMALIZED_ICON" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}.png"        > /dev/null
    DOUBLE=$((SIZE * 2))
    sips -z $DOUBLE $DOUBLE "$NORMALIZED_ICON" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
rm -f "$NORMALIZED_ICON"
rm -rf "$ICONSET_DIR"
echo "  Icon written to $ICNS_PATH"

# ── 4. Write Info.plist ───────────────────────────────────────────────────────
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDisplayName</key><string>OPTCG Alt Art Switcher</string>
  <key>CFBundleExecutable</key><string>OPTCGAltArtSwitcher</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.camiloguerrero.optcg-alt-art-switcher</string>
  <key>CFBundleName</key><string>OPTCG Alt Art Switcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# ── 5. Code sign ──────────────────────────────────────────────────────────────
# Strip resource-fork / Finder xattrs that codesign rejects as 'detritus'
find "$APP" -exec xattr -c {} \; 2>/dev/null || true
echo "▶ Signing…"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

echo ""
echo "✅ Built $APP"
echo "   Architectures: $(lipo -archs "$APP/Contents/MacOS/OPTCGAltArtSwitcher")"
