"""Trace app_icon_no_bg.png into Android vector drawable paths.

Strategy:
  1. Load the 512x512 transparent PNG.
  2. Build a binary mask from the alpha channel.
  3. Run potrace to produce Bezier curve paths.
  4. Convert potrace curves to SVG-style "M / C / L / Z" path data.
  5. Scale path coords from image pixel space (0..512) into the target
     viewport. We use a 192-unit viewport to match Android adaptive icons
     (matches existing ic_launcher_*.xml conventions).
  6. Emit a complete <vector> XML so the splash icon is fully resolution
     independent.
"""
from PIL import Image
import numpy as np
import potrace
from pathlib import Path

SRC = Path("D:/Flutter_Projucts/PicaComic/PicaKeep/plan/图片/PicaComic_original_icons/images/app_icon_no_bg.png")
DST = Path("D:/Flutter_Projucts/PicaComic/PicaKeep/.claude/worktrees/pedantic-golick-d963ab/android/app/src/main/res/drawable/launch_glyph.xml")

VIEWPORT = 192.0  # target vector viewport size (unitless, like adaptive icons)
FILL_COLOR = "#2196F3"  # the brand blue baked into ic_launcher_blue_foreground.webp

img = Image.open(SRC).convert("RGBA")
W, H = img.size
print(f"source: {W}x{H}")

# Build binary mask from alpha channel: opaque pixels become foreground.
# potrace expects truthy = foreground (black). The PNG has the glyph as
# opaque pixels, so a direct alpha-threshold gives us the right polarity.
alpha = np.array(img)[:, :, 3]
mask = (alpha > 64)
print(f"opaque pixel count: {int(mask.sum())}")

# potrace expects a 2D bitmap.
bmp = potrace.Bitmap(mask)
path = bmp.trace(
    turdsize=2,           # ignore tiny noise blobs
    alphamax=1.0,         # smoothness of corner detection
    opttolerance=0.2,     # bezier optimisation tolerance
)

# Scale factor from pixel coords (0..512) to viewport (0..192).
scale = VIEWPORT / max(W, H)


def fmt(v: float) -> str:
    # Drop trailing zeros, keep at most 3 decimals (~0.5 px @ 192 viewport).
    return f"{round(v * scale, 3):g}"


def is_full_frame(curve) -> bool:
    """potrace emits the outer image rectangle as the first curve when
    foreground does not touch the frame. Detect it by checking whether
    the curve consists solely of corner segments hugging x in {0, W} and
    y in {0, H}."""
    pts = [curve.start_point] + [seg.end_point for seg in curve]
    on_edge = all(
        (round(p.x) in (0, W) or round(p.y) in (0, H)) for p in pts
    )
    return on_edge and all(seg.is_corner for seg in curve)


def path_data() -> str:
    parts = []
    for idx, curve in enumerate(path):
        if is_full_frame(curve):
            print(f"  skip frame curve #{idx}")
            continue
        # Each curve is one closed sub-path: M start, then segments, Z.
        s = curve.start_point
        parts.append(f"M{fmt(s.x)},{fmt(s.y)}")
        for seg in curve:
            if seg.is_corner:
                a = seg.c
                b = seg.end_point
                parts.append(f"L{fmt(a.x)},{fmt(a.y)}")
                parts.append(f"L{fmt(b.x)},{fmt(b.y)}")
            else:
                a = seg.c1
                b = seg.c2
                c = seg.end_point
                parts.append(
                    f"C{fmt(a.x)},{fmt(a.y)} {fmt(b.x)},{fmt(b.y)} {fmt(c.x)},{fmt(c.y)}"
                )
        parts.append("Z")
    return "".join(parts)


d = path_data()
print(f"path data length: {len(d)} chars")

xml = f'''<?xml version="1.0" encoding="utf-8"?>
<!--
  Auto-traced from plan/PicaComic_original_icons/images/app_icon_no_bg.png
  (512x512 transparent master) into a {int(VIEWPORT)}-unit viewport.
  Resolution-independent: stays sharp at any splash size.
-->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="{int(VIEWPORT)}dp"
    android:height="{int(VIEWPORT)}dp"
    android:viewportWidth="{VIEWPORT:g}"
    android:viewportHeight="{VIEWPORT:g}">
    <path
        android:fillColor="{FILL_COLOR}"
        android:fillType="evenOdd"
        android:pathData="{d}" />
</vector>
'''

DST.write_text(xml, encoding="utf-8")
print(f"wrote {DST} ({len(xml)} bytes)")
