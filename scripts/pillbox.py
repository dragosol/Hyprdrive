#!/usr/bin/env python3
"""Find the dock pill in a screenshot: prints "x0 x1 y0 y1".

FOUND, not predicted. x47_cell.py predicts the pill from Dock.cpp's constants
because it is testing the layout; a rig that only needs somewhere to aim wants
the opposite -- reading the geometry back keeps it from being a second copy of
layout() that drifts.

The pill is the widest bright horizontal run in the bottom eighth of the frame:
it is a frosted plate over a wallpaper, so it is brighter than what surrounds
it, and nothing else down there is that wide.

usage: pillbox.py <png>
"""
import sys

import numpy as np
from PIL import Image


def main():
    a = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(np.int32)
    h, w = a.shape[:2]
    top = int(h * 0.875)
    lum = a[top:, :, :].mean(axis=2)
    bright = lum > (lum.mean() + 12)
    cols = np.where(bright.sum(axis=0) > 8)[0]
    rows = np.where(bright.sum(axis=1) > 8)[0]
    if len(cols) < 20 or len(rows) < 5:
        sys.exit("pillbox: no pill found")
    print("%d %d %d %d" % (cols.min(), cols.max(), top + rows.min(), top + rows.max()))


if __name__ == "__main__":
    main()
