#!/usr/bin/env python3
"""Y7 gate: the dock's drag glow is CONTINUOUS in the drag's distance.

Six frames of one live drag, rung 0 above the bottom-30% band and rungs 1..5
walking from the band's top edge down to the pill. The glow is an 18px halo, so
it is measured in an ANNULUS around the pill -- the pill's own box grown by 24px
with the box itself cut out -- against rung 0, which is the same drag with the
cursor above the band and therefore the same everything minus the glow.

Three claims, and the middle one is the one the spec insists on:

  OFF ABOVE THE BAND   rung 0 vs rung 1 is near nothing
  CONTINUOUS           the rungs rise in steps, none of which is the whole rise
  FULL AT THE PILL     the last rung is the brightest

usage: y7_gate.py <dir>
"""
import sys

import numpy as np
from PIL import Image


def load(p):
    return np.asarray(Image.open(p).convert("RGB")).astype(np.int32)


def main():
    d = sys.argv[1]
    frames = [load("%s/rung%d.png" % (d, i)) for i in range(6)]
    h, w = frames[0].shape[:2]

    # The pill, found rather than predicted: it is the widest bright horizontal
    # run in the bottom eighth of a frame taken with no glow. Predicting it from
    # Dock.cpp's constants would make this a second implementation of layout().
    base = frames[0]
    bottom = base[int(h * 0.875):, :, :]
    lum = bottom.mean(axis=2)
    bright = lum > (lum.mean() + 12)
    cols = np.where(bright.sum(axis=0) > 8)[0]
    rows = np.where(bright.sum(axis=1) > 8)[0]
    if len(cols) < 20 or len(rows) < 5:
        print("ABORT: could not find the pill in rung0")
        return 2
    x0, x1 = int(cols.min()), int(cols.max())
    y0 = int(h * 0.875) + int(rows.min())
    y1 = int(h * 0.875) + int(rows.max())
    print("pill found at x %d..%d  y %d..%d" % (x0, x1, y0, y1))

    PAD = 24
    outer = np.zeros((h, w), bool)
    outer[max(0, y0 - PAD):min(h, y1 + PAD), max(0, x0 - PAD):min(w, x1 + PAD)] = True
    inner = np.zeros((h, w), bool)
    inner[y0:y1, x0:x1] = True
    ring = outer & ~inner
    print("annulus %d px" % int(ring.sum()))

    vals = []
    for i, f in enumerate(frames):
        diff = np.abs(f - frames[0]).mean(axis=2)
        vals.append(float(diff[ring].mean()))

    for i, v in enumerate(vals):
        print("rung %d  glow %.3f" % (i, v))

    steps = [vals[i + 1] - vals[i] for i in range(1, 5)]
    rise = vals[5] - vals[1]

    off = vals[1] < 0.5
    rising = all(s > 0 for s in steps)
    # No single step may carry most of the rise: that is the switch-at-a-boundary
    # the spec rules out.
    biggest = max(steps) / rise if rise > 0 else 1.0
    continuous = rising and biggest < 0.60
    full = vals[5] == max(vals)

    print("\nrise %.3f   steps %s   biggest step = %.0f%% of the rise" % (rise, ["%.3f" % s for s in steps], biggest * 100))
    print("off above the band : %s (%.3f)" % ("yes" if off else "NO", vals[1]))
    print("continuous         : %s" % ("yes" if continuous else "NO -- it steps"))
    print("full at the pill   : %s" % ("yes" if full else "NO"))

    if rise < 1.0:
        print("\nY7 FAIL -- there is no glow to speak of (rise %.3f)" % rise)
        return 1
    if off and continuous and full:
        print("\nY7 PASS -- the glow tracks the drag's distance continuously")
        return 0
    print("\nY7 FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
