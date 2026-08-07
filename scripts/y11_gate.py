#!/usr/bin/env python3
"""Y11 gate: a non-active-desktop dock preview is NON-BLANK and LIVE.

NON-BLANK is a colour count inside the panel band -- the fixture's magenta,
which the wallpaper does not contain (the c-frames prove that rather than the
claim).

LIVE is a changed-pixel count between two hover frames, measured ONLY inside
the cell the magenta found. Restricting it there matters: the frost, the
wallpaper and the dock's own hover highlight all move, and a whole-band diff
would report those as a live preview.

The control pair c0/c1 is taken the same distance apart with nothing hovered,
so the floor comes from this run's wallpaper rather than a remembered number.

usage: y11_gate.py <dir> <tag>
"""
import sys

import numpy as np
from PIL import Image


def load(p):
    return np.asarray(Image.open(p).convert("RGB")).astype(np.int16)


def magenta(a):
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    return (r > 110) & (b > 110) & (g < 90) & (r - g > 60) & (b - g > 60)


def changed(a, b, mask):
    d = np.abs(a - b).max(axis=2)
    return int(((d > 25) & mask).sum())


def main():
    d, tag = sys.argv[1], sys.argv[2]
    f = {n: load("%s/%s-%s.png" % (d, tag, n)) for n in ("c0", "c1", "h0", "h1", "h2")}

    mag = {n: magenta(f[n]) for n in f}
    nblank = int(mag["h0"].sum())
    ctrl_mag = max(int(mag["c0"].sum()), int(mag["c1"].sum()))

    rows = mag["h0"].sum(axis=1)
    solid = int((rows > (mag["h0"].shape[1] // 40)).sum())

    # The CELL: where the preview actually is, dilated a little so the digits at
    # its edges count. Taken from the hover frame, never from a predicted box.
    ys, xs = np.where(mag["h0"])
    cell = np.zeros(mag["h0"].shape, bool)
    if len(ys):
        y0, y1 = max(0, ys.min() - 4), min(cell.shape[0], ys.max() + 5)
        x0, x1 = max(0, xs.min() - 4), min(cell.shape[1], xs.max() + 5)
        cell[y0:y1, x0:x1] = True

    live01 = changed(f["h0"], f["h1"], cell)
    live12 = changed(f["h1"], f["h2"], cell)
    noise = changed(f["c0"], f["c1"], cell)
    area = int(cell.sum())

    # PIPELINE LIVENESS. The whole screen, between the same two instants as
    # h0/h1. Y11B ticks on the HOME desktop, so these frames must differ however
    # the preview behaves -- if they do not, the capture is stale and "the
    # preview is a still" is a reading of grim, not of the plugin.
    p0, p1 = load("%s/%s-p0.png" % (d, tag)), load("%s/%s-p1.png" % (d, tag))
    pipeline = changed(p0, p1, np.ones(p0.shape[:2], bool))

    print("cell area          %d px" % area)
    print("PIPELINE   p0>p1=%d px changed on the whole screen" % pipeline)
    print("NON-BLANK  magenta h0=%-8d control=%-6d solid rows=%d" % (nblank, ctrl_mag, solid))
    print("LIVE       h0>h1=%-8d h1>h2=%-8d control c0>c1=%d" % (live01, live12, noise))

    floor = max(200, noise * 5)
    nonblank_ok = nblank > max(400, ctrl_mag * 4) and solid >= 40
    live_ok = live01 > floor and live12 > floor

    if pipeline < 2000:
        print("\nPIPELINE STALE (%d) -- the capture handed back the same frame twice." % pipeline)
        print("Nothing below can be read as a statement about the plugin.")
        return 2

    print("\nlive floor         %d  (5x the unhovered control, min 200)" % floor)
    print("NON-BLANK: %s" % ("pass" if nonblank_ok else "FAIL -- the cell is a hole"))
    print("LIVE:      %s" % ("pass" if live_ok else "FAIL -- the preview is a still"))

    if nonblank_ok and live_ok:
        print("\nY11 PASS -- an off-desktop preview renders the real window and keeps drawing")
        return 0
    print("\nY11 FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
