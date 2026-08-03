#!/usr/bin/env python3
"""X26 (drag from the overview into the dock) + the dock polish, host-side.

Reads what the rig left in share/x26/. Every coordinate the rig used was measured
off a frame from the same run, so nothing here assumes a fixed layout.

P1  released on the pill  -> the window is minimized (special:minimized)
P2  released 28px ABOVE the pill -> it is not. The near miss is the point: it
    proves the reject is the pill's own bounds, not "the cursor went low".
P3  the proxy SHRINKS while over the pill, by the strip's mini scale rather than
    a second animation, and the released window ends up inside the pill.
P4  hovering an icon lights it and labels it; not hovering does neither.
P5  the icon sits equidistant from the pill's top and bottom.
"""
import json
import sys

import numpy as np
from PIL import Image

FIXTURE = "x26fix"
ICON = 54  # dock:icon_size default; the pill is ITEM_PAD_TOP + ICON + ITEM_PAD_BOTTOM


def clients(name):
    with open(f"clients_{name}.json") as f:
        return {c["class"]: c["workspace"]["name"] for c in json.load(f)}


def green(png):
    """The LARGEST CONNECTED BLOB of fixture green, never the bounding box of
    every green pixel. The same window is green in the main tile, in its strip
    mini AND in its desktop card, so the union box spans 2327px in every frame
    and P3a's shrink ratio is pinned at exactly 1.00 whatever the proxy does --
    a check that cannot fail, the same family as X1's bestScale clamp.
    Labelled on a 4x downsample; there is no scipy on this host.
    """
    im = np.asarray(Image.open(png).convert("RGB")).astype(int)
    mask = (im[:, :, 1] > 150) & (im[:, :, 0] < 110) & (im[:, :, 2] < 110)
    if not mask.any():
        return None

    S = 4
    small = mask[::S, ::S]
    seen = np.zeros_like(small)
    best, best_n = None, 0
    for sy, sx in zip(*np.where(small)):
        if seen[sy, sx]:
            continue
        stack, comp = [(sy, sx)], []
        seen[sy, sx] = True
        while stack:
            y, x = stack.pop()
            comp.append((y, x))
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < small.shape[0] and 0 <= nx < small.shape[1] \
                        and small[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        if len(comp) > best_n:
            best, best_n = comp, len(comp)

    ys, xs = np.array(best).T
    return (xs.min() * S, ys.min() * S,
            (xs.max() - xs.min() + 1) * S, (ys.max() - ys.min() + 1) * S)


def pill(png):
    """The pill reads as the only thing brighter than the overview's backdrop in
    the bottom band."""
    lum = np.asarray(Image.open(png).convert("RGB")).astype(float).mean(2)
    ys, xs = np.where(lum[1480:1600, :] > 19.3)
    return xs.min(), ys.min() + 1480, xs.max(), ys.max() + 1480


def band_diff(a, b, y0):
    A = np.asarray(Image.open(a).convert("RGB")).astype(int)[y0:]
    B = np.asarray(Image.open(b).convert("RGB")).astype(int)[y0:]
    return int((np.abs(A - B).sum(2) > 25).sum())


HOME, OVER = green("drag_home_dock.png"), green("drag_over_dock.png")
POST = green("post_dock.png")
PX0, PY0, PX1, PY1 = pill("hover_off.png")

ratio = OVER[2] / HOME[2]
# The pill is measured from post_dock.png itself: minimizing ADDS a preview slot,
# so the pill is wider there than in the control frame and a fixed box would
# reject a preview that is sitting exactly where it should.
QX0, QY0, QX1, QY1 = pill("post_dock.png")
inside = POST and QX0 <= POST[0] and POST[0] + POST[2] <= QX1 + 1 and QY0 <= POST[1] and POST[1] + POST[3] <= QY1 + 1
# The tooltip sits ABOVE the pill, the highlight inside it, so the band starts
# well above the pill's top edge.
hover_px = band_diff("hover_off.png", "hover_on.png", PY0 - 140)
idle_px = band_diff("hover_off.png", "hover_off.png", PY0 - 140)

ok = True
for name, cond, detail in [
    ("P1 drop on the pill minimizes",
     clients("dock").get(FIXTURE) == "special:minimized", f"{FIXTURE} -> {clients('dock').get(FIXTURE)}"),
    ("P2 a near miss does not commit",
     clients("miss").get(FIXTURE) == "1", f"{FIXTURE} -> {clients('miss').get(FIXTURE)}"),
    ("P3a proxy shrinks over the pill",
     0.20 < ratio < 0.60, f"{HOME[2]}px -> {OVER[2]}px ({ratio:.2f}x)"),
    ("P3b released window lands in the pill",
     bool(inside),  f"post {POST} pill x {QX0}..{QX1}"),
    ("P4 hover lights and labels the icon",
     hover_px > 2000 and idle_px == 0, f"{hover_px}px changed, idle control {idle_px}px"),
    ("P5 pill is padded evenly around the icon",
     (PY1 - PY0 + 1 - ICON) % 2 == 0 and PY1 - PY0 + 1 > ICON,
     f"pill h={PY1 - PY0 + 1}, icon={ICON}, pad={(PY1 - PY0 + 1 - ICON) / 2} each side"),
]:
    print(("PASS " if cond else "FAIL ") + name + "  " + detail)
    ok &= bool(cond)

sys.exit(0 if ok else 1)
