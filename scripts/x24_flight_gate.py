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
FLY = [f"fly{i}.png" for i in range(1, 6)]


def pill(png):
    """Same detection the X26 gate uses: the pill is the only thing brighter
    than the overview's backdrop in the bottom band."""
    lum = np.asarray(Image.open(png).convert("RGB")).astype(float).mean(2)
    ys, xs = np.where(lum[1480:1600, :] > 19.3)
    return xs.min(), ys.min() + 1480, xs.max(), ys.max() + 1480


with open("clients.json") as f:
    where = {c["class"]: c["workspace"]["name"] for c in json.load(f)}

OPEN = largest_green("pre.png")
LAND = largest_green("landed.png")
SEQ = [largest_green(p) for p in FLY]
PX0, PY0, PX1, PY1 = pill("landed.png")
DEFAULT_MS = int(open("default_ms.txt").read())

widths = [b[2] if b else 0 for b in SEQ]
mids = [b[1] + b[3] / 2 if b else 0 for b in SEQ]
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
    ("P6 lands in the pill",
     PX0 <= LAND[0] and LAND[0] + LAND[2] <= PX1 + 1 and PY0 <= LAND[1] and LAND[1] + LAND[3] <= PY1 + 1,
     f"landed {LAND} pill x {PX0}..{PX1} y {PY0}..{PY1}"),
    ("P7 shipping duration is an Apple-band exit",
     150 <= DEFAULT_MS <= 300, f"dock:minimize_ms default {DEFAULT_MS}ms"),
]:
    print(("PASS " if cond else "FAIL ") + name + "  " + detail)
    ok &= bool(cond)

sys.exit(0 if ok else 1)
