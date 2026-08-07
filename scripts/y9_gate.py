#!/usr/bin/env python3
"""Y9 gate: a minimized window is out of the overview until a query matches it.

Counts the two fixtures' colours across five states. The magenta window is the
minimized one; the green window never matches the query and is the LIVENESS
CONTROL -- if the typing never reached the search bar, green does not change
either, which is how the 2026-08-06 run failed and read as a product fault.

Presence is a colour count AND a solid-row count. The row count is what stops a
handful of stray wallpaper pixels reading as a tile, and what makes "it came
back as one tile among several" measurable without predicting where the tile is.

usage: y9_gate.py <dir> <tag>
"""
import sys

import numpy as np
from PIL import Image


def load(p):
    return np.asarray(Image.open(p).convert("RGB")).astype(np.int16)


def magenta(a):
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    return (r > 110) & (b > 110) & (g < 90) & (r - g > 60) & (b - g > 60)


def green(a):
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    return (g > 100) & (r < 90) & (b < 90) & (g - r > 50) & (g - b > 50)


def score(mask):
    px = int(mask.sum())
    rows = mask.sum(axis=1)
    solid = int((rows > (mask.shape[1] // 60)).sum())
    return px, solid


def main():
    d, tag = sys.argv[1], sys.argv[2]
    states = ("desktop", "minimized", "q0", "q1", "q2")
    m, g = {}, {}
    for s in states:
        a = load("%s/%s-%s.png" % (d, tag, s))
        m[s] = score(magenta(a))
        g[s] = score(green(a))

    print("%-10s %-22s %s" % ("state", "magenta (minimized)", "green (control)"))
    for s in states:
        print("%-10s %8d px %4d rows   %8d px %4d rows" % (s, m[s][0], m[s][1], g[s][0], g[s][1]))

    # The magenta window must have been visible SOMEWHERE first, or "absent"
    # below is a statement about the fixture rather than about the gate.
    visible = m["desktop"][0] > 20000 and m["desktop"][1] > 200
    gone_when_minimized = m["minimized"][1] < 20
    gone_no_query = m["q0"][1] < 20
    back_when_filtered = m["q1"][1] >= 20 and m["q1"][0] > 2000
    gone_again = m["q2"][1] < 20

    # LIVENESS: the query has to have DONE something to the frame. Green does not
    # match "MAGWIN", so any change in it is the filter reflowing the grid.
    filter_live = abs(g["q1"][0] - g["q0"][0]) > 3000

    print()
    print("fixture was visible on the desktop : %s" % ("yes" if visible else "NO -- rig fault"))
    print("filter reached the search bar      : %s (green %d -> %d)" % ("yes" if filter_live else "NO -- rig fault", g["q0"][0], g["q1"][0]))
    print("hidden while minimized, no query   : %s" % ("yes" if gone_when_minimized and gone_no_query else "NO"))
    print("BACK when the query matches        : %s" % ("yes" if back_when_filtered else "NO"))
    print("hidden again once the query clears : %s" % ("yes" if gone_again else "NO"))

    if not visible or not filter_live:
        print("\nY9 INCONCLUSIVE -- the rig did not establish its own preconditions.")
        return 2
    if gone_when_minimized and gone_no_query and back_when_filtered and gone_again:
        print("\nY9 PASS -- a minimized window is out of the overview until a query matches it")
        return 0
    print("\nY9 FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
