#!/usr/bin/env bash
# Generates AppIcon.icns using a Swift one-liner + sips + iconutil
set -euo pipefail

DEST="${1:-.}"
ICONSET_DIR="/tmp/MeOrThem.iconset"
SWIFT_ICON_SCRIPT="/tmp/gen_icon.swift"

mkdir -p "$ICONSET_DIR"

# Write a Swift script that draws the icon
cat > "$SWIFT_ICON_SCRIPT" << 'SWIFT_EOF'
import AppKit
import CoreGraphics

func drawIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    // Background: deep dark circle
    let bg = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: s - 4, height: s - 4))
    NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1).setFill()
    bg.fill()

    // Outer ring
    let ring = NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: s - 8, height: s - 8))
    ring.lineWidth = max(2, s * 0.04)
    NSColor(red: 0.18, green: 0.95, blue: 0.42, alpha: 1).setStroke()
    ring.stroke()

    // Signal bars (5 bars in the lower-center)
    let barCount = 5
    let totalBarsWidth = s * 0.55
    let barWidth = totalBarsWidth / CGFloat(barCount * 2 - 1)
    let gap = barWidth
    let maxBarH = s * 0.38
    let startX = (s - totalBarsWidth) / 2
    let baseY = s * 0.28
    let colors: [NSColor] = [
        NSColor(red: 0.18, green: 0.95, blue: 0.42, alpha: 1),
        NSColor(red: 0.18, green: 0.95, blue: 0.42, alpha: 1),
        NSColor(red: 0.98, green: 0.82, blue: 0.08, alpha: 1),
        NSColor(red: 0.98, green: 0.82, blue: 0.08, alpha: 1),
        NSColor(red: 0.98, green: 0.22, blue: 0.22, alpha: 1),
    ]
    let heights: [CGFloat] = [1.0, 0.8, 0.65, 0.45, 0.3]
    for i in 0..<barCount {
        let barH = maxBarH * heights[i]
        let x = startX + CGFloat(i) * (barWidth + gap)
        let rect = NSRect(x: x, y: baseY, width: barWidth, height: barH)
        let path = NSBezierPath(roundedRect: rect, xRadius: barWidth * 0.2, yRadius: barWidth * 0.2)
        colors[i].setFill()
        path.fill()
    }

    // "MOT" text
    let fontSize = max(8, s * 0.14)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
        .foregroundColor: NSColor(white: 0.85, alpha: 1),
    ]
    let str = NSAttributedString(string: "MOT", attributes: attrs)
    let strSize = str.size()
    str.draw(at: NSPoint(x: (s - strSize.width) / 2, y: s * 0.62))

    image.unlockFocus()
    return image
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconsetDir = CommandLine.arguments[1]

for sz in sizes {
    let img = drawIcon(size: sz)
    let scale1x = sz
    // Convert via tiffRepresentation to get a proper NSBitmapImageRep
    if let tiff = img.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff),
       let data = bitmap.representation(using: .png, properties: [:]) {
        let url = URL(fileURLWithPath: "\(iconsetDir)/icon_\(scale1x)x\(scale1x).png")
        try! data.write(to: url)
    }
}
print("Icons generated in \(iconsetDir)")
SWIFT_EOF

# Run the Swift script to generate PNGs
swift "$SWIFT_ICON_SCRIPT" "$ICONSET_DIR" 2>/dev/null || {
    echo "  ⚠️  Icon generation failed (non-fatal), using default icon."
    exit 0
}

# Use sips to generate all required sizes from the 1024 source
SOURCE="$ICONSET_DIR/icon_1024x1024.png"
if [ ! -f "$SOURCE" ]; then
    echo "  ⚠️  Source icon not found, skipping icns generation."
    exit 0
fi

# Generate all required icon sizes
for SIZE in 16 32 128 256 512; do
    sips -z $SIZE $SIZE "$SOURCE" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}.png" 2>/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z $DOUBLE $DOUBLE "$SOURCE" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}@2x.png" 2>/dev/null
done
# 512@2x = 1024
cp "$SOURCE" "$ICONSET_DIR/icon_512x512@2x.png"

# Convert to .icns
iconutil --convert icns "$ICONSET_DIR" --output "$DEST/AppIcon.icns" 2>/dev/null && \
    echo "  ✅  AppIcon.icns generated" || \
    echo "  ⚠️  iconutil failed, app will use default icon"

# Cleanup
rm -rf "$ICONSET_DIR" "$SWIFT_ICON_SCRIPT"
