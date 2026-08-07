#!/usr/bin/env python3
"""Y8 gate: the landing icon hops ONCE.

"kind of like in macos" and, in the spec's words, "not a decaying bounce train".
That is a claim about a SHAPE OVER TIME, so this reads the series of frames the
probe took of the pill and asks three things of it:

  IT HAPPENS      the pill region departs from its resting state at all
  ONE PEAK        the departure rises and falls exactly once, with no second
                  hump above a third of the first -- a train would show several
  IT SETTLES      the last frames are back at the resting state

The resting state is taken from the frames themselves (the median of the last
quarter) rather than from the pre-drag baseline: the pointer ends up parked on
the pill, so the hover highlight is a constant offset that has nothing to do
with the bounce and would otherwise be counted as one.

usage: y8_gate.py <dir> <pillTop>
"""
import glob
import sys

import numpy as np
from PIL import Image


def main():
    d, ptop = sys.argv[1], int(sys.argv[2])
    files = sorted(glob.glob("%s/f*.png" % d))
    if len(files) < 10:
        print("ABORT: only %d frames" % len(files))
        return 2

    band = [np.asarray(Image.open(f).convert("RGB")).astype(np.int32)[ptop - 30:] for f in files]

    # WALLPAPER GUARD. hyprwall rotating mid-run changes the whole screen and
    # every reading after it is worthless; it shows up as a colossal step in the
    # WHOLE frame that the pill band alone would not explain.
    full = [np.asarray(Image.open(f).convert("RGB")).astype(np.int32) for f in (files[0], files[-1])]
    if int((np.abs(full[0] - full[1]).mean(axis=2) > 25).sum()) > 500000:
        print("ABORT: the screen changed wholesale during the run (wallpaper rotation?)")
        return 2

    rest = np.median(np.stack(band[-max(4, len(band) // 4):]), axis=0)
    vals = [float((np.abs(b - rest).mean(axis=2) > 20).sum()) for b in band]

    for i, v in enumerate(vals):
        print("%2d %6.0f %s" % (i, v, "#" * min(60, int(v / 40))))

    peak = max(vals)
    if peak < 300:
        print("\nY8 FAIL -- the pill never moved (peak %.0f)" % peak)
        return 1

    hi = peak * 0.35
    # Contiguous runs above the threshold. One hop is one run; a decaying train
    # is several, each smaller than the last.
    runs, cur = [], []
    for i, v in enumerate(vals):
        if v >= hi:
            cur.append(i)
        elif cur:
            runs.append(cur)
            cur = []
    if cur:
        runs.append(cur)

    settled = vals[-1] < peak * 0.2

    print("\npeak %.0f   humps above 35%% of it: %d %s" % (peak, len(runs), [ (r[0], r[-1]) for r in runs ]))
    print("settles at the end : %s (%.0f)" % ("yes" if settled else "NO", vals[-1]))
    print("one hop            : %s" % ("yes" if len(runs) == 1 else "NO -- %d humps" % len(runs)))

    if len(runs) == 1 and settled:
        print("\nY8 PASS -- the icon hops once and settles")
        return 0
    print("\nY8 FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
