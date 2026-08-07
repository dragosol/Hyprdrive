#!/usr/bin/env python3
"""Z1 gate. Counts the fixture's MAGENTA inside the hover panel band.

Two hovers of one window in one state, separated only by desktop swaps:
  h0  before any swap  -- must show the preview
  h1  after the swaps  -- must show it too
with an unhovered control (c0/c1) beside each, so an empty h-frame cannot be
excused as a hover that never landed.

usage: z1_gate.py <dir> <tag>
"""
import sys

import numpy as np
from PIL import Image


def load(path):
    return np.asarray(Image.open(path).convert("RGB")).astype(np.int16)


def magenta(a):
    """Saturated magenta: red and blue high, green low. The kitty fixture is
    #ff00ff; the frost over it and the downscale to a 132px cell both pull it
    toward the backdrop, so this is deliberately loose on the exact value and
    strict on the SHAPE of the colour (green must actually be the odd one out).
    """
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    return (r > 110) & (b > 110) & (g < 90) & (r - g > 60) & (b - g > 60)


def main():
    d, tag = sys.argv[1], sys.argv[2]
    counts = {}
    for name in ("c0", "h0", "c1", "h1"):
        img = load("%s/%s-%s.png" % (d, tag, name))
        m = magenta(img)
        counts[name] = int(m.sum())
        # Largest solid RUN of magenta rows: a real preview cell is a block ~132
        # rows tall, while stray matches from the wallpaper are scattered.
        rows = m.sum(axis=1)
        wide = rows > (m.shape[1] // 40)
        best = run = 0
        for v in wide:
            run = run + 1 if v else 0
            best = max(best, run)
        counts[name + "_rows"] = int(best)

    for name in ("c0", "h0", "c1", "h1"):
        print("%-3s magenta=%-8d solid_rows=%d" % (name, counts[name], counts[name + "_rows"]))

    # The controls say the band is clean when nothing is hovered. Without this a
    # magenta wallpaper would make every hover pass.
    ctrl = max(counts["c0"], counts["c1"])
    floor = max(400, ctrl * 4)

    before_ok = counts["h0"] > floor and counts["h0_rows"] >= 40
    after_ok = counts["h1"] > floor and counts["h1_rows"] >= 40

    print("\ncontrol max=%d  floor=%d" % (ctrl, floor))
    print("BEFORE swaps: %s" % ("preview drawn" if before_ok else "PREVIEW MISSING"))
    print("AFTER  swaps: %s" % ("preview drawn" if after_ok else "PREVIEW MISSING"))

    if before_ok and after_ok:
        print("\nZ1 PASS -- the preview survives the desktop swaps")
        return 0
    if before_ok and not after_ok:
        print("\nZ1 FAIL -- reproduced: the preview is drawn until the desktops are swapped")
        return 1
    print("\nZ1 INCONCLUSIVE -- the BEFORE hover did not draw either, so this run")
    print("measures something other than the reported bug (rig, not product).")
    return 2


if __name__ == "__main__":
    sys.exit(main())
