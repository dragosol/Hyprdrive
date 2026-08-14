#!/usr/bin/env python3
"""Locate a flat-coloured tile in an overview capture (host side).

Same traps as attic/x1_tilebox.py: the overview DIMS tiles so exact-RGB finds
nothing (match on channel dominance), and the wallpaper is red-dominant in
places (take the largest CONNECTED COMPONENT and fill-test it, never a global
bbox). The strip band is excluded by row -- its cards carry the same colours at
a much smaller size.

usage: x43_tilebox.py <shot.png> red|blue|green
"""
import sys
from collections import deque

import numpy as np
from PIL import Image

path, hue = sys.argv[1], sys.argv[2]
a = np.asarray(Image.open(path).convert("RGB")).astype(int)
R, G, B = a[:, :, 0], a[:, :, 1], a[:, :, 2]

if hue == "red":
    m = (R > 90) & (G < R - 60) & (B < R - 60) & (np.abs(G - B) < 60)
elif hue == "blue":
    m = (B > 90) & (R < B - 60) & (G < B - 60)
elif hue == "green":
    m = (G > 90) & (R < G - 60) & (B < G - 60)
else:
    print("bad hue"), sys.exit(2)

m[:260, :] = False

S = 4
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
print("box x=[%d,%d] y=[%d,%d] %dx%d fill=%.2f cells=%d" % (x0, x1, y0, y1, x1 - x0, y1 - y0, fill, len(best)))
if fill < 0.75:
    print("WARN: low fill, not a clean rectangle -- do not trust as a grab point")
    sys.exit(1)
print("GX=%d GY=%d" % ((x0 + x1) // 2, (y0 + y1) // 2))
