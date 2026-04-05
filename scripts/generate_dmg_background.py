#!/usr/bin/env python3
"""Generate DMG installer background for MeOrThem.

Outputs:
  scripts/assets/dmg_background.png     — 540×320  (1x)
  scripts/assets/dmg_background@2x.png  — 1080×640 (2x, Retina)

Requires macOS with PyObjC (ships with macOS, no pip install needed).
"""
import os, sys

try:
    import AppKit
    import Quartz
except ImportError:
    print("❌  PyObjC not available. Requires macOS.")
    sys.exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_DIR    = os.path.join(SCRIPT_DIR, "assets")
OUT_PNG    = os.path.join(OUT_DIR, "dmg_background.png")

os.makedirs(OUT_DIR, exist_ok=True)

# ── Dimensions ────────────────────────────────────────────────────────────────
# DMG window: {200,150,1000,650} → 800×500 logical → 1600×1000 at @2x
W, H = 1600, 1000

# Icon centres in @2x image coords (Quartz: origin = bottom-left)
# Finder logical {220,240}: x_img = 220*2=440, y_img = (500-240)*2=520
APP_X, APP_Y   = 440, 520
APPL_X, APPL_Y = 1160, 520

# ── Helpers ───────────────────────────────────────────────────────────────────
def srgb(r, g, b, a=1.0):
    return AppKit.NSColor.colorWithSRGBRed_green_blue_alpha_(r, g, b, a)

def srgb_hex(h, a=1.0):
    return srgb(int(h[0:2],16)/255, int(h[2:4],16)/255, int(h[4:6],16)/255, a)

# ── Draw ──────────────────────────────────────────────────────────────────────
img = AppKit.NSImage.alloc().initWithSize_((W, H))
img.lockFocus()
ctx = AppKit.NSGraphicsContext.currentContext().CGContext()

# Background gradient: #1c1c1e → #111113 (top to bottom in screen space = H→0 in Quartz)
cs = Quartz.CGColorSpaceCreateDeviceRGB()
gradient = Quartz.CGGradientCreateWithColorComponents(
    cs,
    # top colour                      bottom colour
    [0.11, 0.11, 0.118, 1.0,   0.067, 0.067, 0.075, 1.0],
    [0.0, 1.0], 2
)
Quartz.CGContextDrawLinearGradient(
    ctx, gradient,
    (0, H), (0, 0),   # top → bottom
    Quartz.kCGGradientDrawsBeforeStartLocation | Quartz.kCGGradientDrawsAfterEndLocation
)

# ── Drop-zone circles (subtle, behind icons) ──────────────────────────────────
for cx, cy in [(APP_X, APP_Y), (APPL_X, APPL_Y)]:
    r = 110
    srgb(1, 1, 1, 0.04).set()
    circle = AppKit.NSBezierPath.bezierPathWithOvalInRect_(
        AppKit.NSMakeRect(cx - r, cy - r, r * 2, r * 2)
    )
    circle.fill()
    srgb(1, 1, 1, 0.07).set()
    circle.setLineWidth_(1.5)
    circle.stroke()

# ── Arrow — gentle rightward arc just below icon midline ──────────────────────
ax_start = APP_X  + 130   # 430
ax_end   = APPL_X - 130   # 650
ay_start = APP_Y  - 20    # 320 — slightly below icon centre
ay_end   = APP_Y  - 20    # same height on arrival
ctrl_y   = ay_start - 55  # dips below: gentle downward bow

ORANGE = srgb_hex("FF9F0A")
mx = (ax_start + ax_end) / 2

# Shaft
shaft = AppKit.NSBezierPath.bezierPath()
shaft.setLineWidth_(5.5)
shaft.moveToPoint_((ax_start, ay_start))
shaft.curveToPoint_controlPoint1_controlPoint2_(
    (ax_end, ay_end),
    (mx - 20, ctrl_y),
    (mx + 20, ctrl_y)
)
ORANGE.set()
shaft.stroke()

# Arrowhead — filled chevron at tip
hs = 26
tip_x, tip_y = ax_end, ay_end
arrowhead = AppKit.NSBezierPath.bezierPath()
arrowhead.moveToPoint_((tip_x,              tip_y))
arrowhead.lineToPoint_((tip_x - hs,         tip_y + hs * 0.52))
arrowhead.lineToPoint_((tip_x - hs * 0.42,  tip_y))
arrowhead.lineToPoint_((tip_x - hs,         tip_y - hs * 0.52))
arrowhead.closePath()
ORANGE.set()
arrowhead.fill()

# ── Labels under each icon ────────────────────────────────────────────────────
para = AppKit.NSMutableParagraphStyle.alloc().init()
para.setAlignment_(AppKit.NSTextAlignmentCenter)

def draw_label(text, cx, y, size, alpha):
    a = {
        AppKit.NSFontAttributeName:            AppKit.NSFont.systemFontOfSize_(size),
        AppKit.NSForegroundColorAttributeName: srgb(1, 1, 1, alpha),
        AppKit.NSParagraphStyleAttributeName:  para,
    }
    s = AppKit.NSAttributedString.alloc().initWithString_attributes_(text, a)
    s.drawInRect_(AppKit.NSMakeRect(cx - 200, y, 400, 50))

draw_label("MeOrThem",    APP_X,  APP_Y  - 150, 26, 0.50)
draw_label("Applications", APPL_X, APPL_Y - 150, 26, 0.50)

img.unlockFocus()

# ── Save PNG ──────────────────────────────────────────────────────────────────
def save_png(ns_image, path):
    tiff = ns_image.TIFFRepresentation()
    rep  = AppKit.NSBitmapImageRep.imageRepWithData_(tiff)
    png  = rep.representationUsingType_properties_(
        AppKit.NSBitmapImageFileTypePNG, None
    )
    ok = png.writeToFile_atomically_(path, True)
    if ok:
        print(f"  ✅  {path}")
    else:
        print(f"  ❌  Failed to write {path}")
        sys.exit(1)

save_png(img, OUT_PNG)

print()
print("  Background image ready.")
