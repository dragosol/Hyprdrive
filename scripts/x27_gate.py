#!/usr/bin/env python3
"""X27 gate. Runs on the HOST -- the guest has no PIL/numpy.

Measures the dock pill that actually landed on screen against the reference
Dash to Dock proportions, by diffing an enabled frame against a disabled one.
The predicted box is recomputed here from the SAME reference numbers the plugin
uses, so a change to either side has to be made in both places on purpose.
"""
import json
import sys
import numpy as np
from PIL import Image

D = "/home/dragos/hyprvm/share/x27"

# Reference, read off Dash to Dock's stylesheet.css (#dashtodockContainer.bottom)
# and the user's dumped dconf. Not eyeballed.
ICON = 54
PAD_TOP, PAD_BOTTOM = 10, 14
MARGIN_X, CONTAINER_PAD_X, EDGE_MARGIN = 2, 10, 4
FRACTION = 0.90

off1 = np.asarray(Image.open(f"{D}/off1.png").convert("RGB")).astype(int)
off2 = np.asarray(Image.open(f"{D}/off2.png").convert("RGB")).astype(int)
off3 = np.asarray(Image.open(f"{D}/off3.png").convert("RGB")).astype(int)
on = np.asarray(Image.open(f"{D}/on.png").convert("RGB")).astype(int)
mon = json.load(open(f"{D}/monitors.json"))[0]
clients = json.load(open(f"{D}/clients.json"))

classes = []
for c in clients:
    if c["mapped"] and c["class"] and c["class"] not in classes:
        classes.append(c["class"])
n = len(classes)

# Live window content (a blinking cursor, an animating demo) churns between any
# two frames and swamped the first run of this gate. Whatever moves with the
# dock DISABLED cannot be the dock.
noise = (np.abs(off2 - off1).sum(axis=2) > 8) | (np.abs(off3 - off2).sum(axis=2) > 8)

# Churn does not land on the same pixel twice -- a caret moves, an animation
# advances -- so an exact mask leaks a fringe around every churning region.
# Grow it by 3px in each direction. The dock is 252x78 of solid change; it does
# not care, and this is cheaper than pulling in scipy for one dilation.
for _ in range(3):
    noise[1:] |= noise[:-1]
    noise[:-1] |= noise[1:]
    noise[:, 1:] |= noise[:, :-1]
    noise[:, :-1] |= noise[:, 1:]

diff = (np.abs(on - off2).sum(axis=2) > 8) & ~noise
print(f"noise mask (dock off, frame to frame): {int(noise.sum())} px excluded")

count = int(diff.sum())
if count == 0:
    print("FAIL nothing changed that was not already churning -- the dock never drew")
    sys.exit(1)

# A periodic animation can be still across BOTH control frames and only move for
# the ON one (measured: a 20x8 spinner in widget-factory), so the mask cannot
# catch everything. The dock is one solid blob, so measure the biggest connected
# region rather than the bbox of every surviving pixel -- which is also the
# honest thing to measure: a bbox is not a shape.
def largest_blob(mask):
    seen = np.zeros_like(mask)
    best = None
    for seed in zip(*np.nonzero(mask)):
        if seen[seed]:
            continue
        stack, px = [seed], []
        seen[seed] = True
        while stack:
            y, x = stack.pop()
            px.append((y, x))
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < mask.shape[0] and 0 <= nx < mask.shape[1] and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        if best is None or len(px) > len(best):
            best = px
    return best


blob = largest_blob(diff)
ys = np.array([p[0] for p in blob])
xs = np.array([p[1] for p in blob])
x0, x1, y0, y1 = int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max())
got = (x0, y0, x1 - x0 + 1, y1 - y0 + 1)
print(f"largest connected blob: {len(blob)} px of {count} that survived the mask")

# Predicted, from the reference stackup.
scale = mon["scale"]
mw, mh = mon["width"] / scale, mon["height"] / scale
chrome = 2 * CONTAINER_PAD_X + 2 * MARGIN_X * n
icon = max(8.0, min(ICON, (FRACTION * mw - chrome) / n))
w, h = chrome + icon * n, PAD_TOP + icon + PAD_BOTTOM
want = (round((mw - w) / 2 * scale), round((mh - EDGE_MARGIN - h) * scale), round(w * scale), round(h * scale))

TOL = 2  # rounded corners cost at most a pixel of the extremal row/column
ok = all(abs(g - p) <= TOL for g, p in zip(got, want))

print(f"classes ({n}): {classes}")
print(f"monitor  {mon['width']}x{mon['height']} scale {scale}")
print(f"want pill x,y,w,h = {want}")
print(f"got  pill x,y,w,h = {got}   ({count} px differ)")
print(f"{'PASS' if ok else 'FAIL'} P1 pill geometry matches the reference stackup (tol {TOL}px)")

# P2: it is a PILL, not a rectangle -- the corners must be clipped by the radius.
# Sample a point well inside the 24px corner arc and the pill's own centre line.
r = round(24 * scale)
corner = diff[y0 + 2, x0 + 2]
edge = diff[y0 + round(h * scale / 2), x0 + 2]
p2 = (not corner) and edge
print(f"{'PASS' if p2 else 'FAIL'} P2 corner rounded: top-left inset(2,2) drawn={bool(corner)} (want False), "
      f"left edge at mid-height drawn={bool(edge)} (want True)")

# P3: the pill is TRANSLUCENT, not an opaque slab. 0.19 alpha over a blur must
# still track the wallpaper underneath it: a flat fill would have ~zero variance.
band = on[y0 + 8:y1 - 8, x0 + 8:x1 - 8]
var = float(band.std())
p3 = var > 3.0
print(f"{'PASS' if p3 else 'FAIL'} P3 frosted, not a flat slab: stddev inside the pill = {var:.1f} (want > 3)")

print("X27_RESULT " + ("OK" if (ok and p2 and p3) else "FAIL"))
sys.exit(0 if (ok and p2 and p3) else 1)
