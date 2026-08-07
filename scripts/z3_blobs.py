#!/usr/bin/env python3
"""Largest connected blob of a named fixture colour, on the host.

Same reasoning as scripts/blob.py, which this generalises: the BOUNDING BOX of
every pixel of one colour spans the main tile AND the strip mini AND the
desktop card at once, so a centre taken from it points at empty space between
them. The largest connected component is the one thing on screen that is
actually the tile you meant.

No scipy here, so the flood fill runs on a 4x downsample.

usage: z3_blobs.py <png> <colour> [colour...]
       prints "<colour> <cx> <cy> <w> <h> <px>" per colour, or "<colour> NONE"
"""
import sys

import numpy as np
from PIL import Image

S = 4

# Loose on purpose: an overview tile is frosted, scaled and composited over a
# wallpaper, so the fixture's #ff0000 arrives as something near it. What must
# stay strict is which channel DOMINATES -- that is what keeps red, yellow and
# cyan from matching each other.
COLOURS = {
    "red": lambda r, g, b: (r > 120) & (g < 90) & (b < 90),
    "yellow": lambda r, g, b: (r > 120) & (g > 120) & (b < 100),
    "cyan": lambda r, g, b: (g > 120) & (b > 120) & (r < 100),
    "magenta": lambda r, g, b: (r > 120) & (b > 120) & (g < 100),
    "green": lambda r, g, b: (g > 130) & (r < 110) & (b < 110),
}


def largest(png, colour):
    im = np.asarray(Image.open(png).convert("RGB")).astype(int)
    r, g, b = im[:, :, 0], im[:, :, 1], im[:, :, 2]
    mask = COLOURS[colour](r, g, b)
    if not mask.any():
        return None

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

    ys = [c[0] for c in best]
    xs = [c[1] for c in best]
    y0, y1 = min(ys) * S, (max(ys) + 1) * S
    x0, x1 = min(xs) * S, (max(xs) + 1) * S
    return ((x0 + x1) // 2, (y0 + y1) // 2, x1 - x0, y1 - y0, best_n * S * S)


def main():
    png = sys.argv[1]
    for colour in sys.argv[2:]:
        hit = largest(png, colour)
        if hit is None:
            print("%s NONE" % colour)
        else:
            print("%s %d %d %d %d %d" % ((colour,) + hit))


if __name__ == "__main__":
    main()
