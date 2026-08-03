#!/usr/bin/env python3
"""Strip focus-outline gate. Runs on the HOST over share/x3b/shots/.

Asserts the outline's corner radii track the cell's POSITION, which is the whole
bug: one radius for every cell traced a shape the cell underneath does not have.

P1 the first cell's outer (left) arc is much larger than its facing (right) arc.
P2 an inner cell's arcs are both tight, and match the first cell's facing arc.
P3 the stroke is continuous along the top edge -- the first attempt at splitting
   the asymmetric case clipped by damage and drew nothing at all, which P1/P2
   alone cannot see because they only read the corners.
"""
import sys

import numpy as np
from PIL import Image

BAND = (234, 252)  # rows spanning the top stroke and its arcs
LARGE_MIN, TIGHT_MAX = 12, 8


def arc(png, zone, side):
    lum = np.asarray(Image.open(png).convert("RGB")).astype(float).mean(2)
    edge = []
    for y in range(*BAND):
        hit = np.where(lum[y, zone[0]:zone[1]] > 172)[0]
        if len(hit):
            edge.append(hit.min() if side == "l" else hit.max())
    base = min(edge) if side == "l" else max(edge)
    # max, not the first row: the band opens one row above the stroke, where the
    # strip backdrop is bright enough to read as an inset of 0 and hide a large arc.
    return max(abs(e - base) for e in edge)


def top_run(png, x0, x1):
    lum = np.asarray(Image.open(png).convert("RGB")).astype(float).mean(2)
    fill = np.median(lum[BAND[1] + 8, x0:x1])
    row = lum[BAND[0] + 1, x0:x1]
    return float((row > fill + 40).mean())


first, inner = "shots/first.png", "shots/inner.png"
fl, fr = arc(first, (725, 800), "l"), arc(first, (900, 960), "r")
il, ir = arc(inner, (950, 1020), "l"), arc(inner, (1130, 1190), "r")
run = top_run(first, 760, 930)

ok = True
for name, cond, detail in [
    ("P1 first cell: outer arc large, facing arc tight",
     fl >= LARGE_MIN and fr <= TIGHT_MAX, f"left={fl} right={fr}"),
    ("P2 inner cell: both arcs tight",
     il <= TIGHT_MAX and ir <= TIGHT_MAX, f"left={il} right={ir}"),
    ("P3 split stroke is continuous, not corners only",
     run > 0.95, f"top-edge coverage={run:.2f}"),
]:
    print(("PASS " if cond else "FAIL ") + name + "  " + detail)
    ok &= cond

sys.exit(0 if ok else 1)
