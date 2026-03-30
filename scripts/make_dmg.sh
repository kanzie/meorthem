#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="MeOrThem"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    "$ROOT_DIR/Sources/$APP_NAME/Resources/Info.plist" 2>/dev/null || echo "1.0")
DMG_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"
TMP_DMG="$BUILD_DIR/${APP_NAME}_tmp.dmg"
VOLUME_NAME="$APP_NAME"
DMG_SIZE="60m"

if [ ! -d "$APP_PATH" ]; then
    echo "❌  $APP_PATH not found. Run scripts/build.sh first."
    exit 1
fi

echo "==> Creating DMG for $APP_NAME..."

# Remove old DMGs
rm -f "$DMG_PATH" "$TMP_DMG"

# Create a writable DMG
hdiutil create \
    -srcfolder "$APP_PATH" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,b=16" \
    -format UDRW \
    -size "$DMG_SIZE" \
    "$TMP_DMG"

# Attach it
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP_DMG" | \
    grep -E '^/dev/' | sed 1q | awk '{print $1}')
MOUNT_POINT=$(hdiutil info | grep "$VOLUME_NAME" | tail -1 | awk '{print $NF}')

# Wait a moment
sleep 2

# Create Applications symlink
ln -sf /Applications "/Volumes/$VOLUME_NAME/Applications"

# Set DMG window appearance via AppleScript
echo "==> Setting DMG window layout..."
osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {400, 100, 940, 420}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set position of item "$APP_NAME.app" of container window to {150, 150}
        set position of item "Applications" of container window to {390, 150}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
EOF

# Detach
hdiutil detach "$DEVICE"

# Convert to compressed read-only
hdiutil convert "$TMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH"

# Cleanup
rm -f "$TMP_DMG"

echo ""
echo "  ✅  DMG created: $DMG_PATH"
echo ""
echo "  Share and install:"
echo "  1. Mount $APP_NAME.dmg"
echo "  2. Drag $APP_NAME.app to Applications"
echo "  3. Right-click → Open → Open (first launch only)"
