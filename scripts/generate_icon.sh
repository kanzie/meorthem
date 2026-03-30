#!/usr/bin/env bash
# Generates AppIcon.icns using Swift (preferred) or Python3 fallback + sips + iconutil
set -euo pipefail

DEST="${1:-.}"
mkdir -p "$DEST"
ICONSET_DIR="/tmp/MeOrThem.iconset"
SWIFT_ICON_SCRIPT="/tmp/gen_icon.swift"
PYTHON_ICON_SCRIPT="/tmp/gen_icon.py"
SOURCE_PNG="$ICONSET_DIR/icon_source_1024.png"

mkdir -p "$ICONSET_DIR"

# ── Attempt 1: Swift (rich icon) ─────────────────────────────────────────────
generate_with_swift() {
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

let iconsetDir = CommandLine.arguments[1]
let img = drawIcon(size: 1024)
if let tiff = img.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiff),
   let data = bitmap.representation(using: .png, properties: [:]) {
    let url = URL(fileURLWithPath: "\(iconsetDir)/icon_source_1024.png")
    try! data.write(to: url)
    print("Swift icon generated")
}
SWIFT_EOF

    swift "$SWIFT_ICON_SCRIPT" "$ICONSET_DIR" 2>/dev/null
    return $?
}

# ── Attempt 2: Python3 (simple gradient icon) ─────────────────────────────────
generate_with_python() {
cat > "$PYTHON_ICON_SCRIPT" << 'PYTHON_EOF'
import struct, zlib, sys, math

def make_png(size):
    w, h = size, size
    rows = []
    for y in range(h):
        row = [0]  # filter type
        for x in range(w):
            # Dark background circle with green ring
            cx, cy = w / 2, h / 2
            r = math.sqrt((x - cx) ** 2 + (y - cy) ** 2)
            maxR = w * 0.48
            ringW = w * 0.04
            if r < maxR - ringW:
                # Interior: dark navy
                t = r / (maxR - ringW)
                rv = int(18 + t * 8)
                gv = int(18 + t * 8)
                bv = int(28 + t * 10)
                av = 255 if r < maxR - ringW * 0.5 else 200
            elif r < maxR:
                # Ring: green
                rv, gv, bv, av = 46, 243, 108, 255
            else:
                rv, gv, bv, av = 0, 0, 0, 0
            row.extend([rv, gv, bv, av])
        rows.append(bytes(row))

    raw = b''.join(rows)
    compressed = zlib.compress(raw, 9)

    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        crc = zlib.crc32(tag + data) & 0xffffffff
        return c + struct.pack('>I', crc)

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', compressed)
    png += chunk(b'IEND', b'')
    return png

dest = sys.argv[1]
size = 1024
data = make_png(size)
with open(f"{dest}/icon_source_1024.png", "wb") as f:
    f.write(data)
print("Python icon generated")
PYTHON_EOF

    python3 "$PYTHON_ICON_SCRIPT" "$ICONSET_DIR" 2>/dev/null
    return $?
}

# ── Generate source PNG ───────────────────────────────────────────────────────
echo "  Generating source icon..."
if generate_with_swift; then
    echo "  ✅  Icon generated via Swift"
elif generate_with_python; then
    echo "  ✅  Icon generated via Python3"
else
    echo "  ⚠️  Icon generation failed (non-fatal), app will use default icon."
    rm -rf "$ICONSET_DIR" "$SWIFT_ICON_SCRIPT" "$PYTHON_ICON_SCRIPT" 2>/dev/null
    exit 0
fi

# Verify source exists
if [ ! -f "$SOURCE_PNG" ]; then
    echo "  ⚠️  Source icon not found, skipping icns generation."
    exit 0
fi

# ── Resize to all required iconset sizes using sips ──────────────────────────
for SIZE in 16 32 128 256 512; do
    DOUBLE=$((SIZE * 2))
    sips -z "$SIZE" "$SIZE"     "$SOURCE_PNG" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}.png"     2>/dev/null
    sips -z "$DOUBLE" "$DOUBLE" "$SOURCE_PNG" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}@2x.png" 2>/dev/null
done
# 512@2x = 1024 (copy source)
cp "$SOURCE_PNG" "$ICONSET_DIR/icon_512x512@2x.png"

# Remove source PNG from iconset (iconutil rejects non-standard filenames)
rm -f "$SOURCE_PNG"

# ── Convert iconset to icns ───────────────────────────────────────────────────
iconutil --convert icns "$ICONSET_DIR" --output "$DEST/AppIcon.icns" 2>/dev/null && \
    echo "  ✅  AppIcon.icns written to $DEST" || \
    echo "  ⚠️  iconutil failed — app will use default icon"

# Cleanup
rm -rf "$ICONSET_DIR" "$SWIFT_ICON_SCRIPT" "$PYTHON_ICON_SCRIPT" 2>/dev/null
