#!/usr/bin/env python3
"""Measure the X26 rig's targets off a frame from the run that will use them.

points <png>  -> grabX grabY pillCentreX pillTopY
icon   <png>  -> the centre of the first dock icon
"""
import sys

import numpy as np
from PIL import Image

png, what = sys.argv[1], sys.argv[2]
im = np.asarray(Image.open(png).convert("RGB")).astype(int)
lum = im.mean(2)

# Same detection the gate uses, so the rig and the gate cannot disagree about
# where the pill is.
ys, xs = np.where(lum[1480:1600, :] > 19.3)
px0, px1 = xs.min(), xs.max()
py0, py1 = ys.min() + 1480, ys.max() + 1480

if what == "icon":
    # Geometric, not by blob: the fixture classes have no `.desktop` entry, so
    # `appIcon()` returns null and their slots render EMPTY. The pill's interior
    # measures 44.7-50.0 luminance end to end -- there is no icon to find. Two
    # running classes means two equal slots, so the first one's centre is a
    # quarter of the way across.
    print(px0 + (px1 - px0 + 1) // 4, (py0 + py1) // 2)
    sys.exit()

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
