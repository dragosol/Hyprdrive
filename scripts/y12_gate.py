#!/usr/bin/env python3
"""Y12 grader: a stashed window homed on the active desktop takes ONE slot.

Five frames, all with the same query typed and the same two fixtures:

    ctrlA  both windows on ws5             <- control, before
    lap1   one of them stashed FROM ws5    <- measured
    lap2   ...again                        <- measured
    lap3   ...again                        <- measured
    ctrlB  restored, both on ws5 again     <- control, after

Two windows are two tiles in every frame, so the TILE BLOCK -- the union of the
two located tiles -- must sit in the same place in all five. With the duplicate
in, the active grid solves for three, picks two rows, fills row 0 and leaves row
1 empty, and the block rides up by a quarter of the usable band.

Structure, not colour: the colours only LOCATE the two tiles (the wallpaper is
pinned greyscale, so neither can be forged by a picture). The verdict is
geometry -- one connected blob per fixture, of tile size, and the block's centre
where the control put it.

usage: y12_gate.py <dir> <tag>
"""
import sys

import numpy as np
from PIL import Image

# The main area only: above this band is the strip and the search chrome (which
# carry mini copies of the very colours we locate), below it is the dock.
BAND_Y0, BAND_Y1 = 400, 1330
# The active card. Neighbour cards are empty in this rig; clipping to the card
# keeps a tile that escaped onto one from being read as part of the block.
BAND_X0, BAND_X1 = 200, 2360

MIN_TILE_PX = 120000  # a real tile is ~700x450; a stray icon is a few hundred
CENTRE_TOL = 16       # px; the defect moves the block by ~250
# Looser than the centre on purpose: a tile edge is a rounded, frosted corner
# rather than a step, so the located width moves a few px with the wallpaper
# under it. The defect is not a size change, so this only has to stay far below
# a whole extra column.
SIZE_TOL = 32


def load(p):
    return np.asarray(Image.open(p).convert("RGB")).astype(np.int16)


def green(a):
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    return (g > 100) & (r < 100) & (b < 100) & (g - r > 50) & (g - b > 50)


def magenta(a):
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    return (r > 110) & (b > 110) & (g < 90) & (r - g > 60) & (b - g > 60)


def blobs(mask, step=4):
    """Connected components of `mask`, on a step-downsampled grid.

    Doctrine: the largest CONNECTED blob, never a bounding box. Two tiles of the
    same colour in different places would otherwise merge into one huge rect and
    read as a single well-placed tile.
    """
    m = mask[::step, ::step]
    h, w = m.shape
    seen = np.zeros_like(m, dtype=bool)
    out = []
    for sy in range(h):
        for sx in range(w):
            if not m[sy, sx] or seen[sy, sx]:
                continue
            stack = [(sy, sx)]
            seen[sy, sx] = True
            ys, xs = [], []
            while stack:
                y, x = stack.pop()
                ys.append(y)
                xs.append(x)
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < h and 0 <= nx < w and m[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        stack.append((ny, nx))
            out.append({
                "px": len(ys) * step * step,
                "x0": min(xs) * step, "x1": max(xs) * step,
                "y0": min(ys) * step, "y1": max(ys) * step,
            })
    out.sort(key=lambda b: -b["px"])
    return out


def tiles(path):
    a = load(path)
    band = np.zeros(a.shape[:2], dtype=bool)
    band[BAND_Y0:BAND_Y1, BAND_X0:BAND_X1] = True
    found = {}
    for name, pred in (("green", green), ("magenta", magenta)):
        bs = [b for b in blobs(pred(a) & band) if b["px"] >= MIN_TILE_PX]
        found[name] = bs
    return found


def main():
    d, tag = sys.argv[1], sys.argv[2]
    names = ("ctrlA", "lap1", "lap2", "lap3", "ctrlB")

    raw = {}
    for n in names:
        raw[n] = tiles("%s/%s-%s.png" % (d, tag, n))

    # LIVENESS. Two frames captured minutes apart must not be the same bytes --
    # a frozen capture pipeline would make every geometry below agree perfectly.
    a0 = load("%s/%s-ctrlA.png" % (d, tag))
    a1 = load("%s/%s-ctrlB.png" % (d, tag))
    fresh = bool((a0 != a1).any())

    print("%-7s %-38s %s" % ("frame", "green tile", "magenta tile"))
    block = {}
    ok_count = True
    for n in names:
        g, m = raw[n]["green"], raw[n]["magenta"]

        def fmt(bs):
            if len(bs) != 1:
                return "%d blobs" % len(bs)
            b = bs[0]
            return "%4d,%4d %4dx%-4d" % (b["x0"], b["y0"], b["x1"] - b["x0"], b["y1"] - b["y0"])

        print("%-7s %-38s %s" % (n, fmt(g), fmt(m)))
        if len(g) != 1 or len(m) != 1:
            ok_count = False
            block[n] = None
            continue
        x0 = min(g[0]["x0"], m[0]["x0"])
        x1 = max(g[0]["x1"], m[0]["x1"])
        y0 = min(g[0]["y0"], m[0]["y0"])
        y1 = max(g[0]["y1"], m[0]["y1"])
        block[n] = ((x0 + x1) // 2, (y0 + y1) // 2, x1 - x0, y1 - y0)

    print()
    print("%-7s %s" % ("frame", "tile block  centre(x,y)  size(w,h)"))
    for n in names:
        b = block[n]
        print("%-7s %s" % (n, "%5d %5d   %5d %5d" % b if b else "-- not two tiles --"))

    ca, cb = block["ctrlA"], block["ctrlB"]
    controls_agree = bool(
        ca and cb
        and abs(ca[0] - cb[0]) <= CENTRE_TOL and abs(ca[1] - cb[1]) <= CENTRE_TOL
        and abs(ca[2] - cb[2]) <= SIZE_TOL and abs(ca[3] - cb[3]) <= SIZE_TOL
    )

    laps_ok = True
    worst = 0
    if ca:
        for n in ("lap1", "lap2", "lap3"):
            b = block[n]
            if not b:
                laps_ok = False
                continue
            dx, dy = abs(b[0] - ca[0]), abs(b[1] - ca[1])
            dw, dh = abs(b[2] - ca[2]), abs(b[3] - ca[3])
            worst = max(worst, dx, dy)
            print("%-7s vs ctrlA: dcentre %4d,%-4d  dsize %4d,%-4d" % (n, dx, dy, dw, dh))
            if dx > CENTRE_TOL or dy > CENTRE_TOL or dw > SIZE_TOL or dh > SIZE_TOL:
                laps_ok = False
    else:
        laps_ok = False

    print()
    print("capture is live (ctrlA != ctrlB bytes) : %s" % ("yes" if fresh else "NO -- frozen capture"))
    print("exactly two tiles in every frame       : %s" % ("yes" if ok_count else "NO"))
    print("the two controls agree                 : %s" % ("yes" if controls_agree else "NO -- rig fault"))
    print("stashed laps lay out like the control  : %s (worst drift %d px)" % ("yes" if laps_ok else "NO", worst))

    ok = fresh and ok_count and controls_agree and laps_ok
    print()
    print("Y12 %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
