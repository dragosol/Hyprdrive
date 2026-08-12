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
FLY = [f"fly{i}.png" for i in range(1, 11)]
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

# EXCESS green, not absolute green. The flight fades the proxy inside the same
# tween that scales it, so a `G > 150` mask stops seeing the proxy about a third
# of the way in and measures its brightest fragment instead -- which is why P4's
# centre used to wander upward and P5 read the acceleration backwards. The gate
# wallpaper is greyscale (wp17, pinned by the suite), so "greener than its own
# red and blue" is the fixture and nothing else. See blob.largest_green.
EXCESS = 30

# The dock's OWN live preview of the window in flight. A minimize stashes
# immediately, and X25 draws a stashed window in the pill, live -- so from the
# first frame of the flight there is a second green image of the fixture sitting
# in the dock. It is excluded like the panel, and its rectangle is MEASURED off
# landed.png, where the flight is over and it is the only fixture green left.
# (x26_points.pillbox cannot stand in for this: it only looks below y=1480 and
# the pill grows upward to hold a preview -- measured here at y=1192, 322px
# above the plate edge that locator reports.) Without it, frames 7-10 came back
# as four identical 140x136 boxes at (1272,1192): P4's descent reversed and P6
# read 58%.
#
# EVERY such surface, not one: the pill can hold several preview cells, and
# taking them out one at a time is whack-a-mole (the first pass excluded the
# cell at x=1264 and frames 7-10 came straight back with the one at x=1636).
# landed.png is the definition -- the flight is over and the fixture is stashed
# there, so anything still green in it is dock furniture.
MASKS = [PANEL] if PANEL else []
for _ in range(8):
    _b = largest_green("landed.png", MASKS or None, EXCESS)
    if not _b or _b[2] * _b[3] < 2000:
        break
    MASKS.append((int(_b[0]) - 8, int(_b[1]) - 8, int(_b[2]) + 16, int(_b[3]) + 16))
print("dock surfaces excluded from the green search: %s" % (MASKS[1 if PANEL else 0:],))

OPEN = largest_green("pre.png", MASKS, EXCESS)
SEQ = [largest_green(p, MASKS, EXCESS) for p in FLY]

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
# ...and a blob ABOVE where the tile started is not the flight either. The
# flight leaves the tile and travels DOWN into the pill; the overview's desktop
# STRIP sits across the top of the card and holds a mini of the same green
# window, ~1000px above the flight path, and the excess-green mask finds it the
# moment the proxy has faded out from under the absolute one. Measured
# 2026-08-12: frames 6-8 came back 252x92 at y=288 while the tile had started at
# y=676, three identical boxes in a row -- the exact shape that reads as a
# teleport. The floor is the tile's own top edge.
LIVE = [b for b in SEQ if b and b[2] * b[3] >= PROXY_MIN and b[1] >= OPEN[1] - 20]
if len(LIVE) < 3:
    sys.exit("x24 flight: only %d frames carry a proxy -- the burst missed the "
             "flight entirely, there is nothing to grade" % len(LIVE))
LAND = LIVE[-1]
PX0, PY0, PX1, PY1 = pill("landed.png")
DEFAULT_MS = int(open("default_ms.txt").read())
ICX, ICY = [float(v) for v in open("icon.txt").read().split()]

# How far the proxy got from the tile it left toward the icon it was aimed at.
_c = lambda b: (b[0] + b[2] / 2.0, b[1] + b[3] / 2.0)
_d = lambda a, b: ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5
TRAVEL = _d(_c(OPEN), (ICX, ICY))
PROGRESS = 1.0 - _d(_c(LAND), (ICX, ICY)) / max(TRAVEL, 1.0)

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
    # P5 asserted ACCELERATION -- "standing Apple rule: exits accelerate" -- and
    # the flight is EASE_OUT_EXPO, which decelerates from its first frame. Spec
    # 13.14 Y5 is where that is decided: the curve is the host's
    # (MINIMIZE_WINDOW_ANIMATION_MODE = EASE_OUT_EXPO, f(t) = 1 - 2^(-10t)),
    # from the user's "same animations... same speed... as gnome", and it
    # supersedes X54's tighten-and-accelerate reading in as many words. So the
    # predicate is the curve the spec names: the early steps are the big ones.
    # An accelerating curve, or a linear one, fails this.
    ("P5 the curve decelerates, as EASE_OUT_EXPO does",
     early > late, f"first steps avg {early:.0f}px, last steps avg {late:.0f}px, ratio {early / max(late, 1e-6):.2f} (expo, not a ramp)"),
    # The last frame that still HAS a proxy, measured against WHERE IT WAS
    # AIMED. This asked for the proxy's centre to be inside the pill's columns
    # AND its foot to be above the plate, and on a one-slot pill those two are
    # mutually exclusive: a 776x516 tile shrinking onto a 54px icon puts its
    # foot past the plate's top edge at E=0.83 and its centre inside the
    # columns only from E=0.89. Measured 2026-08-12 -- P6 could not be
    # satisfied by any frame of a correct flight, on the fixture the gate
    # itself builds.
    #
    # X46's claim is that the minimize flies into THE APP'S OWN ICON, so the
    # honest measurement is progress from the tile toward that icon (the very
    # coordinate this rig clicked, written beside the frames). The frames stop
    # where the camera stops, not where the flight does -- eight whole-output
    # grims cover the first ~20% of the stretched flight -- so this is a floor
    # on distance covered, and it is what catches a flight aimed somewhere else
    # entirely (Z8's off-screen aim was ~1000px wrong).
    ("P6 the flight travels into its icon",
     PROGRESS >= 0.60 and LAND[1] > OPEN[1],
     f"covered {PROGRESS * 100:.0f}% of the {TRAVEL:.0f}px from the tile to the icon at ({ICX:.0f},{ICY:.0f}); "
     f"last proxy {LAND}; pill x {PX0}..{PX1} top {PY0}"),
    # P7 asserted 150..300, the Apple-exit band, and the shipping default is
    # 400. Spec 13.14 Y5 names 400 explicitly -- GNOME's
    # MINIMIZE_WINDOW_ANIMATION_TIME, "both directions", extracted from
    # windowManager.js -- and says it supersedes the shorten-it request, because
    # expo is ~97% travelled in its first third and so reads tighter than the
    # 220ms bezier it replaced. The gate asserts the spec's number rather than
    # the general rule the spec already reconciled.
    ("P7 shipping duration is GNOME's MINIMIZE_WINDOW_ANIMATION_TIME",
     DEFAULT_MS == 400, f"dock:minimize_ms default {DEFAULT_MS}ms, spec 13.14 Y5 says 400"),
]:
    print(("PASS " if cond else "FAIL ") + name + "  " + detail)
    ok &= bool(cond)

sys.exit(0 if ok else 1)
