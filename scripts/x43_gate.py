#!/usr/bin/env python3
"""X43 gate -- decide which of two overlapping windows is ON TOP, by PIXELS.

X43 has been closed three times on a focus assertion. Focus was never the
property the user reported, and `activewindow` kept saying yes. This gate
refuses to look at focus at all: it samples the geometric intersection of the
two fixture windows and reports which flat colour owns it.

Runs on the HOST -- the guest has no PIL/numpy.

usage: x43_gate.py <shot.png> [clients.json]
"""
import json
import sys

import numpy as np
from PIL import Image

shot = sys.argv[1]
clients = sys.argv[2] if len(sys.argv) > 2 else "/home/dragos/hyprvm/share/x43/fixture-clients.json"

cs = json.load(open(clients))
box = {}
for c in cs:
    if c["class"] in ("X43BOT", "X43TOP"):
        x, y = c["at"]
        w, h = c["size"]
        box[c["class"]] = (x, y, x + w, y + h)

if len(box) != 2:
    print("ABORT: need both X43BOT and X43TOP in %s" % clients)
    sys.exit(2)

bx0, by0, bx1, by1 = box["X43BOT"]
tx0, ty0, tx1, ty1 = box["X43TOP"]
ox0, oy0 = max(bx0, tx0), max(by0, ty0)
ox1, oy1 = min(bx1, tx1), min(by1, ty1)

a = np.asarray(Image.open(shot).convert("RGB")).astype(int)
H, W = a.shape[:2]
# inset so window borders / rounded corners never enter the sample
ox0, oy0 = max(0, ox0 + 24), max(0, oy0 + 24)
ox1, oy1 = min(W, ox1 - 24), min(H, oy1 - 24)
if ox1 <= ox0 or oy1 <= oy0:
    print("ABORT: windows do not overlap on screen")
    sys.exit(2)

patch = a[oy0:oy1, ox0:ox1]
R, G, B = patch[:, :, 0], patch[:, :, 1], patch[:, :, 2]
red = int(((R > 90) & (G < R - 60) & (B < R - 60)).sum())
blue = int(((B > 90) & (R < B - 60) & (G < B - 60)).sum())
total = patch.shape[0] * patch.shape[1]

top = "BOT(red)" if red > blue else "TOP(blue)" if blue > red else "AMBIGUOUS"
print("overlap x=[%d,%d] y=[%d,%d]  %d px" % (ox0, ox1, oy0, oy1, total))
print("red=%d (%.1f%%)  blue=%d (%.1f%%)" % (red, 100.0 * red / total, blue, 100.0 * blue / total))
print("ON_TOP=%s" % top)

want = sys.argv[3] if len(sys.argv) > 3 else None
if want:
    ok = (want == "bot" and red > blue * 4) or (want == "top" and blue > red * 4)
    print("EXPECT=%s RESULT=%s" % (want, "PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)
