#!/usr/bin/env python3
"""Measure a grabbable tile box from an overview capture (host side).

The fixture paints each window a flat colour, so a tile is a large region of one
strong hue. The overview DIMS them, so exact-RGB matching finds nothing -- match
on channel dominance instead, which survives the dim.

Two traps this file exists to avoid, both hit for real:
  - the palette REPEATS on a crowded desktop, so six same-coloured tiles merge
    into one bounding box. Hence the MARKER window (#ff0000), unique in the
    fixture, is the only thing matched here.
  - the wallpaper is orange/gold and is itself red-dominant in places, so a
    global bounding box of the mask spans the whole screen. Hence the largest
    CONNECTED COMPONENT, not the bbox, and a fill test on top.

Prints GX/GY ready to feed x1_stress.sh.
"""
import sys
from collections import deque

import numpy as np
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else "/home/dragos/hyprvm/share/x1/tilebox-rest.png"
a = np.asarray(Image.open(path).convert("RGB")).astype(int)
R, G, B = a[:, :, 0], a[:, :, 1], a[:, :, 2]

m = (R > 100) & (G < R - 70) & (B < R - 70) & (np.abs(G - B) < 60)
m[:260, :] = False          # strip band: same colours, much smaller cells

S = 4                        # downsample; a tile is hundreds of px, this is safe
sm = m[::S, ::S]
h, w = sm.shape
seen = np.zeros_like(sm, bool)
best = None
for j in range(h):
    for i in range(w):
        if not sm[j, i] or seen[j, i]:
            continue
        q = deque([(j, i)])
        seen[j, i] = True
        pts = []
        while q:
            y, x = q.popleft()
            pts.append((y, x))
            for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                ny, nx = y + dy, x + dx
                if 0 <= ny < h and 0 <= nx < w and sm[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    q.append((ny, nx))
        if best is None or len(pts) > len(best):
            best = pts

if best is None or len(best) < 400:
    print("NO_TILE_FOUND largest=%d cells" % (0 if best is None else len(best)))
    sys.exit(1)

ys = [p[0] for p in best]
xs = [p[1] for p in best]
x0, x1, y0, y1 = min(xs) * S, max(xs) * S, min(ys) * S, max(ys) * S
fill = len(best) / max(1, (max(xs) - min(xs) + 1) * (max(ys) - min(ys) + 1))
print("box x=[%d,%d] y=[%d,%d] %dx%d fill=%.2f cells=%d" %
      (x0, x1, y0, y1, x1 - x0, y1 - y0, fill, len(best)))
if fill < 0.75:
    print("WARN: low fill, not a clean rectangle -- do not trust as a grab point")
    sys.exit(1)
print("GX=%d GY=%d" % ((x0 + x1) // 2, (y0 + y1) // 2))
