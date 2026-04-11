#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

################################################################################
# LOAD .env (OPTIONAL)
################################################################################

if [ -f "$ROOT_DIR/.env" ]; then
    echo "==> Loading signing credentials from .env..."
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
    echo "==> No .env file found at $ROOT_DIR/.env — will use ad-hoc (self) signing."
fi

################################################################################
# DETERMINE SIGNING MODE
################################################################################

DEVELOPER_SIGNING=false
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    echo "==> SIGNING_IDENTITY found — will sign with Developer ID certificate."
    DEVELOPER_SIGNING=true
else
    echo "==> SIGNING_IDENTITY not set — falling back to ad-hoc (self) signing."
    echo "   The app will require right-click → Open on first launch (Gatekeeper)."
fi

BUILD_DIR="$ROOT_DIR/build"
APP_NAME="MeOrThem"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
SOURCES_RESOURCES="$ROOT_DIR/Sources/$APP_NAME/Resources"
ENTITLEMENTS="$SOURCES_RESOURCES/MeOrThem.entitlements"

cd "$ROOT_DIR"

################################################################################
# SPEEDTEST BINARY CHECK
################################################################################

echo "==> Checking for speedtest binary..."
if [ ! -f "$SOURCES_RESOURCES/speedtest" ] || [ ! -s "$SOURCES_RESOURCES/speedtest" ]; then
    echo ""
    echo "  ⚠️  Speedtest CLI binary not found."
    echo "  Download from: https://www.speedtest.net/apps/cli"
    echo "  Choose the macOS Universal binary, extract it, and place 'speedtest' at:"
    echo "  $SOURCES_RESOURCES/speedtest"
    echo "  Then: chmod +x \"$SOURCES_RESOURCES/speedtest\""
    echo ""
    echo "  Creating placeholder so build succeeds (speedtest feature will be disabled)..."
    printf '#!/bin/sh\necho "speedtest binary not installed" && exit 1\n' > "$SOURCES_RESOURCES/speedtest"
    chmod +x "$SOURCES_RESOURCES/speedtest"
fi

################################################################################
# BUILD & ASSEMBLE
################################################################################

echo "==> Building $APP_NAME..."
swift build -c release 2>&1

echo "==> Assembling .app bundle..."
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy main binary
cp "$ROOT_DIR/.build/release/$APP_NAME" "$APP_PATH/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "$SOURCES_RESOURCES/Info.plist" "$APP_PATH/Contents/Info.plist"

# Copy speedtest helper into Contents/MacOS — Apple-recommended location for
# helper executables that are signed and run as subprocesses.
cp "$SOURCES_RESOURCES/speedtest" "$APP_PATH/Contents/MacOS/speedtest"
chmod +x "$APP_PATH/Contents/MacOS/speedtest"
xattr -d com.apple.quarantine "$APP_PATH/Contents/MacOS/speedtest" 2>/dev/null || true

# Copy SPM resource bundle if present
BUNDLE_PATH="$ROOT_DIR/.build/release/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$BUNDLE_PATH" ]; then
    cp -r "$BUNDLE_PATH" "$APP_PATH/Contents/Resources/"
fi

# Copy app icon (pre-generated); regenerate if missing
ICON_SRC="$SOURCES_RESOURCES/AppIcon.icns"
if [ ! -f "$ICON_SRC" ] && command -v swift &> /dev/null; then
    echo "==> Regenerating app icon (missing from repo)..."
    bash "$SCRIPT_DIR/generate_icon.sh" "$SOURCES_RESOURCES"
fi
if [ -f "$ICON_SRC" ]; then
    echo "==> Copying app icon..."
    cp "$ICON_SRC" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi

# Touch the bundle to help macOS icon services pick up the new icon
touch "$APP_PATH" 2>/dev/null || true

################################################################################
# CODE SIGNING
################################################################################

if [ "$DEVELOPER_SIGNING" = true ]; then
    echo "==> Signing with Developer ID: $SIGNING_IDENTITY"
    SIGN_OPTS="--force --options runtime --timestamp --sign \"$SIGNING_IDENTITY\""

    echo "==> 1. Finding and signing ALL nested binaries (e.g. speedtest helper)..."
    # Signs every executable inside the bundle except the main app binary itself.
    # Nested binaries must be signed before the outer bundle is sealed.
    #
    # IMPORTANT: speedtest is a third-party helper launched as a subprocess. It must
    # NOT be signed with --options runtime (Hardened Runtime). On macOS 14+, a Hardened
    # Runtime binary with zero entitlements is blocked by AMFI when launched as a
    # subprocess of a Hardened Runtime app — producing "CNSTask.Process error 0".
    # Sign it with Developer ID only (no runtime flag, no entitlements).
    HELPER_SIGN_OPTS="--force --timestamp --sign \"$SIGNING_IDENTITY\""
    find "$APP_PATH" -type f -perm +111 \
        ! -path "$APP_PATH/Contents/MacOS/MeOrThem" | while read -r BINARY; do
        echo "   Signing: $(basename "$BINARY")"
        if [[ "$(basename "$BINARY")" == "speedtest" ]]; then
            eval "codesign $HELPER_SIGN_OPTS \"$BINARY\"" || { echo "❌ Failed to sign $BINARY"; exit 1; }
        else
            eval "codesign $SIGN_OPTS \"$BINARY\"" || { echo "❌ Failed to sign $BINARY"; exit 1; }
        fi
    done

    echo "==> 2. Signing the main App Bundle with entitlements..."
    if [ -f "$ENTITLEMENTS" ]; then
        echo "   Using entitlements: $ENTITLEMENTS"
        eval "codesign $SIGN_OPTS --entitlements \"$ENTITLEMENTS\" \"$APP_PATH\"" || { echo "❌ Failed to sign app bundle"; exit 1; }
    else
        echo "   ❌ ERROR: Entitlements file missing at $ENTITLEMENTS"
        exit 1
    fi

    echo "==> 3. Verifying the code seal (deep verification)..."
    codesign --verify --verbose --deep "$APP_PATH" || { echo "❌ Deep verification failed"; exit 1; }
    echo "==> ✨ Developer ID signing complete!"
else
    echo "==> Applying ad-hoc (self) code signature..."
    echo "   Identity: - (ad-hoc, not trusted by Gatekeeper without right-click → Open)"
    if [ -f "$ENTITLEMENTS" ]; then
        echo "   Applying entitlements: $ENTITLEMENTS"
        codesign --force --deep --sign - \
            --entitlements "$ENTITLEMENTS" \
            "$APP_PATH" 2>&1 || {
            echo "   Entitlements signing failed — signing without entitlements..."
            codesign --force --deep --sign - "$APP_PATH" 2>&1
        }
    else
        codesign --force --deep --sign - "$APP_PATH" 2>&1
    fi
    echo "==> ✨ Ad-hoc signing complete!"
fi

echo ""
echo "  ✅  Build complete: $APP_PATH"
echo ""
echo "  To create DMG: bash scripts/make_dmg.sh"
echo ""
if [ "$DEVELOPER_SIGNING" = false ]; then
    echo "  ⚠️  First launch: right-click MeOrThem.app → Open → Open"
    echo "     (Gatekeeper warning expected for self-signed apps)"
fi
