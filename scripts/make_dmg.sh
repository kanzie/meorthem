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
DMG_SIZE="80m"
BG_PNG="$SCRIPT_DIR/assets/dmg_background.png"

if [ ! -f "$BG_PNG" ]; then
    echo "==> Generating DMG background..."
    python3 "$SCRIPT_DIR/generate_dmg_background.py"
fi

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

# Attach it (allow Finder to auto-open so it registers the disk properly)
ATTACH_OUT=$(hdiutil attach -readwrite -noverify "$TMP_DMG")
DEVICE=$(echo "$ATTACH_OUT" | grep -E '^/dev/' | sed 1q | awk '{print $1}')
MOUNT_POINT=$(echo "$ATTACH_OUT" | grep "Apple_HFS" | awk -F'\t' '{print $NF}' | sed 's/^[[:space:]]*//')

# Wait for Finder to mount
sleep 3
echo "==> Mounted at: $MOUNT_POINT"

# Create Applications symlink
ln -sf /Applications "$MOUNT_POINT/Applications"

# Copy background image and set the macOS hidden attribute on the folder
mkdir -p "$MOUNT_POINT/.background"
cp "$BG_PNG" "$MOUNT_POINT/.background/background.png"
# SetFile requires Xcode CLI tools; fall back to chflags if unavailable
SetFile -a V "$MOUNT_POINT/.background" 2>/dev/null || \
    chflags hidden "$MOUNT_POINT/.background"

# Flush writes before AppleScript touches the volume
sync

# Set DMG window appearance via AppleScript
echo "==> Setting DMG window layout..."
DISK_NAME=$(basename "$MOUNT_POINT")
osascript <<EOF
tell application "Finder"
    tell disk "$DISK_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 150, 1000, 650}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to POSIX file "$MOUNT_POINT/.background/background.png"
        set position of item "$APP_NAME.app" of container window to {220, 240}
        set position of item "Applications" of container window to {580, 240}
        update without registering applications
        delay 5
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
