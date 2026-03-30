#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="MeOrThem"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
SOURCES_RESOURCES="$ROOT_DIR/Sources/$APP_NAME/Resources"

cd "$ROOT_DIR"

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

echo "==> Building $APP_NAME..."
swift build -c release 2>&1

echo "==> Assembling .app bundle..."
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy binary
cp "$ROOT_DIR/.build/release/$APP_NAME" "$APP_PATH/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "$SOURCES_RESOURCES/Info.plist" "$APP_PATH/Contents/Info.plist"

# Copy resources
cp "$SOURCES_RESOURCES/speedtest" "$APP_PATH/Contents/Resources/speedtest"
chmod +x "$APP_PATH/Contents/Resources/speedtest"

# Copy SPM resource bundle if present
BUNDLE_PATH="$ROOT_DIR/.build/release/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$BUNDLE_PATH" ]; then
    cp -r "$BUNDLE_PATH" "$APP_PATH/Contents/Resources/"
fi

# Generate and copy app icon
if command -v swift &> /dev/null; then
    echo "==> Generating app icon..."
    bash "$SCRIPT_DIR/generate_icon.sh" "$APP_PATH/Contents/Resources"
fi

echo "==> Ad-hoc code signing..."
codesign --force --deep --sign - \
    --entitlements "$SOURCES_RESOURCES/MeOrThem.entitlements" \
    "$APP_PATH" 2>&1 || {
    echo "  Code signing failed, trying without entitlements..."
    codesign --force --deep --sign - "$APP_PATH" 2>&1
}

echo ""
echo "  ✅  Build complete: $APP_PATH"
echo ""
echo "  To create DMG: bash scripts/make_dmg.sh"
echo ""
echo "  ⚠️  First launch: right-click MeOrThem.app → Open → Open"
echo "     (Gatekeeper warning is expected for unsigned apps)"
