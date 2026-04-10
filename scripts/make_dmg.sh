#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

################################################################################
# LOAD .env (OPTIONAL)
################################################################################

if [ -f "$ROOT_DIR/.env" ]; then
    echo "==> Loading credentials from .env..."
    while IFS= read -r line || [ -n "$line" ]; do
        # Ignore comments and empty lines
        [[ "$line" =~ ^#.* ]] || [[ -z "$line" ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        clean_key=$(echo "$key" | xargs)
        clean_value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
        export "$clean_key"="$clean_value"
    done < "$ROOT_DIR/.env"
    echo "   .env loaded."
else
    echo "==> No .env file found at $ROOT_DIR/.env — DMG will be created without signing or notarization."
fi

################################################################################
# DETERMINE SIGNING / NOTARIZATION MODE
################################################################################

DEVELOPER_SIGNING=false
NOTARIZE=false

if [ -n "${SIGNING_IDENTITY:-}" ]; then
    echo "==> SIGNING_IDENTITY found — DMG will be signed with Developer ID."
    DEVELOPER_SIGNING=true
    if [ -n "${APPLE_ID:-}" ] && [ -n "${TEAM_ID:-}" ] && [ -n "${APP_PASSWORD:-}" ]; then
        echo "==> Notarization credentials found (APPLE_ID, TEAM_ID, APP_PASSWORD) — will notarize and staple."
        NOTARIZE=true
    else
        echo "==> Notarization credentials incomplete — DMG will be signed but NOT notarized."
        echo "   (Set APPLE_ID, TEAM_ID, APP_PASSWORD in .env to enable notarization)"
    fi
else
    echo "==> SIGNING_IDENTITY not set — skipping signing and notarization."
    echo "   The DMG will contain a self-signed app (right-click → Open required on first launch)."
fi

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

echo "==> Creating DMG for $APP_NAME v$VERSION..."

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
ATTACH_OUT=$(hdiutil attach -readwrite -noverify "$TMP_DMG")
DEVICE=$(echo "$ATTACH_OUT" | grep -E '^/dev/' | sed 1q | awk '{print $1}')
MOUNT_POINT=$(echo "$ATTACH_OUT" | grep "Apple_HFS" | awk -F'\t' '{print $NF}' | sed 's/^[[:space:]]*//')

sleep 3
echo "==> Mounted at: $MOUNT_POINT"

ln -sf /Applications "$MOUNT_POINT/Applications"
sips -z 686 1270 -s dpiWidth 72 -s dpiHeight 72 "$BG_PNG" > /dev/null

mkdir -p "$MOUNT_POINT/.background"
cp "$BG_PNG" "$MOUNT_POINT/.background/background.png"
SetFile -a V "$MOUNT_POINT/.background" 2>/dev/null || \
    chflags hidden "$MOUNT_POINT/.background"

sync

echo "==> Setting DMG window layout..."
DISK_NAME=$(basename "$MOUNT_POINT")
osascript <<EOF
tell application "Finder"
    tell disk "$DISK_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 1370, 786}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to POSIX file "$MOUNT_POINT/.background/background.png"
        set position of item "$APP_NAME.app" of container window to {320, 236}
        set position of item "Applications" of container window to {950, 236}
        update without registering applications
        delay 5
    end tell
end tell
EOF

hdiutil detach "$DEVICE"

# Convert to compressed read-only
hdiutil convert "$TMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH"

rm -f "$TMP_DMG"

################################################################################
# SIGNING, NOTARIZATION & VALIDATION
################################################################################

if [ "$DEVELOPER_SIGNING" = true ]; then
    echo "==> Signing the DMG with Developer ID: $SIGNING_IDENTITY"
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_PATH"

    echo "==> Verifying DMG signature..."
    codesign --verify --verbose "$DMG_PATH" || { echo "❌ DMG signature verification failed"; exit 1; }
    echo "   ✅ DMG signature verified."

    if [ "$NOTARIZE" = true ]; then
        echo "==> Submitting to Apple for notarization (this may take a few minutes)..."
        SUBMISSION_OUT=$(xcrun notarytool submit "$DMG_PATH" \
            --apple-id "$APPLE_ID" \
            --password "$APP_PASSWORD" \
            --team-id "$TEAM_ID" \
            --wait)

        echo "$SUBMISSION_OUT"

        if [[ "$SUBMISSION_OUT" == *"status: Accepted"* ]]; then
            echo "==> ✅ Notarization accepted — stapling ticket to DMG..."
            xcrun stapler staple "$DMG_PATH"

            echo "==> Final Gatekeeper validation..."
            if spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"; then
                echo "   ✅ Gatekeeper accepts this DMG."
            else
                echo "   ❌ Gatekeeper rejected the DMG after notarization."
                exit 1
            fi
        else
            echo "❌ Notarization failed or timed out."
            exit 1
        fi
    else
        echo "==> Skipping notarization — credentials not fully configured in .env."
        echo "   Users will need to right-click → Open on first launch."
    fi
else
    echo "==> Skipping DMG signing and notarization — no SIGNING_IDENTITY configured."
    echo "   The unsigned DMG is still usable; the self-signed app inside requires right-click → Open."
fi

echo ""
echo "  ✅  DMG ready: $DMG_PATH"
if [ "$NOTARIZE" = true ]; then
    echo "  The app is notarized and ready for public distribution."
elif [ "$DEVELOPER_SIGNING" = true ]; then
    echo "  The DMG is Developer ID-signed but not notarized."
else
    echo "  The DMG is unsigned (self-signed app inside)."
fi
