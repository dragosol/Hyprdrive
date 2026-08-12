#!/usr/bin/env python3
"""Measure the X26 rig's targets off a frame from the run that will use them.

points <png>  -> grabX grabY pillCentreX pillTopY
icon   <png>  -> the centre of the first dock icon

`pillbox` is the one place the pill is located, and x26_gate.py imports it from
here so the rig and the gate cannot disagree about where the pill is.
"""
import sys

import numpy as np
from PIL import Image

BAND0 = 1480          # the bottom band the pill lives in, at this guest's 1600px


def _run(flags, minlen):
    """(first, last) of the longest contiguous True run, or None if it is short."""
    idx = np.where(flags)[0]
    if idx.size == 0:
        return None
    breaks = np.where(np.diff(idx) > 1)[0]
    starts = np.concatenate(([0], breaks + 1))
    ends = np.concatenate((breaks, [idx.size - 1]))
    i = int(np.argmax(ends - starts))
    if ends[i] - starts[i] + 1 < minlen:
        return None
    return int(idx[starts[i]]), int(idx[ends[i]])


def pillbox(png_or_lum):
    """(x0, y0, x1, y1) of the dock pill -- SELF-CALIBRATED against the backdrop.

    The threshold used to be the literal 19.3, and 19.3 is the luminance of the
    overview's own flat backdrop on this guest: `> 19.3` therefore decided the
    pill's extent by whether a backdrop pixel rounded to 19.33 or to 19.29.
    Measured 2026-08-12 on wp17 it rounded UP, the mask took 306934 of the
    band's 307200 pixels, and the pill came back as "x 0..2559, y 1480..1599" --
    the band itself. Everything built on that box then measured nothing: the
    icon target landed 600px outside the pill (x=640 for a pill at 1204..1356),
    the containment check became "is the window inside the whole screen", and
    the padding check became "is the band 120px tall".

    So the reference is the band's own MEDIAN, which is the backdrop because the
    backdrop is almost all of it, and the pill is what stands clear of it. The
    pill is a frosted plate: measured on the same frames it runs 43-78 against a
    backdrop of 19.3, so +8 sits in a gap of 24.
    """
    lum = png_or_lum
    if isinstance(png_or_lum, str):
        lum = np.asarray(Image.open(png_or_lum).convert("RGB")).astype(float).mean(2)
    band = lum[BAND0:]
    floor = float(np.median(band)) + 8.0
    bright = band > floor
    # The LONGEST CONTIGUOUS RUN of bright columns, not min..max of all of them:
    # a tooltip, a hover glow or a dragged proxy elsewhere in the band drags a
    # min/max box out to meet it. Measured: hovering at x=640 put something
    # bright there and the box grew to 640..1460 for a pill at 1099..1460.
    cols = _run(bright.sum(axis=0) > 8, 20)
    if cols is None:
        raise SystemExit("x26: no dock pill found in the bottom band (floor %.1f)" % floor)
    x0, x1 = cols
    rows = _run(bright[:, x0:x1 + 1].sum(axis=1) > 24, 8)
    if rows is None:
        raise SystemExit("x26: the pill's columns carry no solid rows (floor %.1f)" % floor)
    return int(x0), int(rows[0]) + BAND0, int(x1), int(rows[1]) + BAND0


def main():
    png, what = sys.argv[1], sys.argv[2]
    im = np.asarray(Image.open(png).convert("RGB")).astype(int)
    lum = im.mean(2)

    px0, py0, px1, py1 = pillbox(lum.astype(float))

    if what == "icon":
        # Geometric, not by blob: the fixture classes have no `.desktop` entry, so
        # `appIcon()` returns null and their slots render EMPTY. The pill's interior
        # measures 44.7-50.0 luminance end to end -- there is no icon to find. Two
        # running classes means two equal slots, so the first one's centre is a
        # quarter of the way across.
        print(px0 + (px1 - px0 + 1) // 4, (py0 + py1) // 2)
        return 0

    # The fixture tile is solid pure green. Take the LARGEST CONNECTED BLOB, never
    # the bounding box of every green pixel: the same window is green in the main
    # tile, in the strip mini AND in its desktop card, so the union box spans 2327px
    # and its centre lands on backdrop between them. A press there grabs nothing,
    # closes the overview, and every later frame then shows the real full-size
    # window -- which reads as "the drop did not commit".
    mask = (im[:, :, 1] > 150) & (im[:, :, 0] < 110) & (im[:, :, 2] < 110)
    S = 4  # label on a downsampled mask; no scipy on this host and full res is slow
    small = mask[::S, ::S]
    seen = np.zeros_like(small)
    best, best_n = None, 0
    for sy, sx in zip(*np.where(small)):
        if seen[sy, sx]:
            continue
        stack, comp = [(sy, sx)], []
        seen[sy, sx] = True
        while stack:
            y, x = stack.pop()
            comp.append((y, x))
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < small.shape[0] and 0 <= nx < small.shape[1] \
                        and small[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        if len(comp) > best_n:
            best, best_n = comp, len(comp)

    ys_, xs_ = np.array(best).T
    print(int(xs_.mean()) * S, int(ys_.mean()) * S, (px0 + px1) // 2, py0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
