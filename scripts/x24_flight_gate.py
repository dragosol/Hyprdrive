#!/usr/bin/env python3
"""X24: the minimize is ANIMATED into the dock, not a teleport.

(x24_gate.py is the older raise/restore gate and still stands; this is the
separate one the handoff asked for -- "do not tick this box until a minimize is
animated" -- so it is entirely about the frames BETWEEN click and landing.)

P1 the click minimizes at all
P2 the flight starts on the OVERVIEW TILE, not the window's real geometry: the
   dock only exists while the overview does, so the tile is what the user is
   watching and anything else would read as a jump
P3 intermediate sizes exist, shrinking monotonically. A teleport gives none
P4 it travels DOWN toward the pill while it shrinks
P5 the curve ACCELERATES (standing Apple rule: exits accelerate). Frames are
   evenly spaced, so convexity is just "later steps bigger than earlier ones"
P6 it ends up inside the pill
P7 the SHIPPING duration is in the Apple band. The flight above is measured at
   2400ms because grim costs ~335ms a frame, so this is the one thing the
   stretched run cannot show for itself.
"""
import json
import os
import sys

# blob.py lives beside this file in the repo and one level up in the share dir.
sys.path[:0] = [os.path.dirname(os.path.abspath(__file__)), "/home/dragos/hyprvm/share"]
import numpy as np
from PIL import Image

from blob import largest_green

FIXTURE = "x24fix"
FLY = [f"fly{i}.png" for i in range(1, 9)]
PROXY_MIN = 5000    # px of fixture green below which there is no proxy left to measure


from x26_points import pillbox        # ONE pill locator for the whole harness


def pill(png):
    """The pill's box. It used to be a private copy of the `lum > 19.3` rule,
    and 19.3 is the luminance of the overview's own backdrop on this guest: the
    box came back as the whole bottom band (x 0..2559, y 1480..1599), so "landed
    in the pill" was really "landed somewhere on the screen" and could not fail.
    x26_points.pillbox() self-calibrates against the band's median instead."""
    return pillbox(png)


with open("clients.json") as f:
    where = {c["class"]: c["workspace"]["name"] for c in json.load(f)}

# The hover preview panel's rectangle, predicted by x47_cell.py from the same
# Dock.cpp constants, written beside the frames by the rig. Excluded from every
# green search below -- see blob.largest_green's `exclude`.
try:
    _p = [int(v) for v in open("panel.txt").read().split()]
    PANEL = tuple(_p) if len(_p) == 4 else None
except (OSError, ValueError):
    PANEL = None
print("hover preview panel excluded from the green search: %s" % (PANEL,))

OPEN = largest_green("pre.png", PANEL)
SEQ = [largest_green(p, PANEL) for p in FLY]

# THE LANDING IS THE LAST FRAME THAT STILL HAS A PROXY, not landed.png.
#
# landed.png has no fixture green in it at all, and that is correct: the flight
# ends with the window stashed, and a stashed window whose class owns no desktop
# entry renders as an EMPTY dock slot -- there is nothing left to find. This
# gate used to read landed.png and get a 196x132 box every time, which was the
# X47 HOVER PREVIEW PANEL: the rig parked the pointer on the icon to click it,
# the panel opened above the pill showing a thumbnail of the very window in
# flight, and largest_green found the panel in every frame. Five identical boxes
# at a fixed y read as a teleport. The rig moves the pointer off the icon now
# (x24_click.sh), so the panel is gone -- and with it the fake landing box.
LIVE = [b for b in SEQ if b and b[2] * b[3] >= PROXY_MIN]
if len(LIVE) < 3:
    sys.exit("x24 flight: only %d frames carry a proxy -- the burst missed the "
             "flight entirely, there is nothing to grade" % len(LIVE))
LAND = LIVE[-1]
PX0, PY0, PX1, PY1 = pill("landed.png")
DEFAULT_MS = int(open("default_ms.txt").read())

widths = [b[2] for b in LIVE]
mids = [b[1] + b[3] / 2 for b in LIVE]
between = [w for w in widths if LAND[2] + 4 < w < OPEN[2] - 4]
steps = [widths[i] - widths[i + 1] for i in range(len(widths) - 1)]
early, late = sum(steps[:2]) / 2, sum(steps[-2:]) / 2

ok = True
for name, cond, detail in [
    ("P1 click minimizes",
     where.get(FIXTURE) == "special:minimized", f"{FIXTURE} -> {where.get(FIXTURE)}"),
    ("P2 flight starts on the overview tile",
     abs(widths[0] - OPEN[2]) < 0.25 * OPEN[2], f"first frame {widths[0]}px vs tile {OPEN[2]}px"),
    ("P3 intermediate sizes, shrinking",
     len(between) >= 2 and all(a >= b for a, b in zip(widths, widths[1:])),
     f"widths {widths}, tile {OPEN[2]}, slot {LAND[2]}, {len(between)} in between"),
    ("P4 travels down to the pill",
     all(a <= b + 4 for a, b in zip(mids, mids[1:])) and mids[-1] > mids[0] + 20,
     f"centres y {[round(m) for m in mids]}"),
    ("P5 the curve accelerates",
     late > early, f"first steps avg {early:.0f}px, last steps avg {late:.0f}px"),
    # The last frame that still HAS a proxy, aimed at the pill. Not "inside" it:
    # the pill is a frosted plate drawn OVER the flight, so the proxy is
    # occluded before it finishes arriving and the last measurable box is a few
    # hundred px above the plate. What is checkable is that it is heading there
    # -- horizontally inside the pill's own columns, and close above its top.
    ("P6 the flight ends at the pill",
     PX0 <= LAND[0] + LAND[2] / 2 <= PX1 and 0 < PY0 - (LAND[1] + LAND[3]) < 250,
     f"last proxy {LAND} centre x {LAND[0] + LAND[2] // 2}, foot {LAND[1] + LAND[3]}; "
     f"pill x {PX0}..{PX1} top {PY0}"),
    ("P7 shipping duration is an Apple-band exit",
     150 <= DEFAULT_MS <= 300, f"dock:minimize_ms default {DEFAULT_MS}ms"),
]:
    print(("PASS " if cond else "FAIL ") + name + "  " + detail)
    ok &= bool(cond)

sys.exit(0 if ok else 1)
