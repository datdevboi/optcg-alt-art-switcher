#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── 1. Compile ────────────────────────────────────────────────────────────────
echo "▶ Building release binary…"
swift build -c release

# ── 2. Assemble .app bundle ───────────────────────────────────────────────────
APP="$ROOT/dist/OPTCG Alt Art Switcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/OPTCGAltArtSwitcher" "$APP/Contents/MacOS/OPTCGAltArtSwitcher"

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
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# ── 5. Ad-hoc code sign ───────────────────────────────────────────────────────
# Strip resource-fork / Finder xattrs that codesign rejects as 'detritus'
find "$APP" -exec xattr -c {} \; 2>/dev/null || true
echo "▶ Signing…"
codesign --force --sign - "$APP"

# ── 6. Remove Gatekeeper quarantine ──────────────────────────────────────────
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# ── 7. Desktop alias ─────────────────────────────────────────────────────────
DESKTOP_LINK=~/Desktop/"OPTCG Alt Art Switcher.app"
rm -f "$DESKTOP_LINK"
ln -s "$APP" "$DESKTOP_LINK"
echo "▶ Desktop alias created at $DESKTOP_LINK"

echo ""
echo "✅ Built $APP"
echo "   Double-click the alias on your Desktop to launch."
