#!/usr/bin/env python3
"""X25 gate. Runs on the HOST -- the guest has no PIL/numpy.

The spec's claim is not "a preview is drawn" but "previews are simply LIVE", and
a stale screenshot pasted into the dock would pass any single-frame test. So the
fixture repaints its WHOLE surface on a 1s cycle and the gate asks whether the
dock band CHANGES between consecutive frames captured 0.8s apart. The changed
blob is also the preview, so the same measurement sizes it.
"""
import json
import sys

import numpy as np
from PIL import Image

D = "/home/dragos/hyprvm/share/x25/shots"

# Reference stackup, same numbers the plugin uses (Dash to Dock stylesheet.css).
ICON = 54
PAD_TOP, PAD_BOTTOM = 10, 14
MIN_ASPECT, MAX_ASPECT = 0.60, 2.20
BAND = 220  # px of screen bottom the pill can possibly occupy


def load(name):
    return np.asarray(Image.open(f"{D}/{name}.png").convert("RGB")).astype(int)


live = [load(f"live{i}") for i in range(5)]
pre0, pre1 = load("pre0"), load("pre1")
mon = json.load(open(f"{D}/monitors.json"))[0]
clients = json.load(open(f"{D}/clients.json"))

H = live[0].shape[0]
band = slice(H - BAND, H)

# P0. A starved output makes every frame identical no matter what the code does
# -- Virtual-1 stalls the whole compositor when the host viewer is hidden -- so
# certify the output was flipping IN THIS RUN before reading anything into a
# frozen preview. The fixture is visible across both control frames.
moved = int((np.abs(pre1 - pre0).sum(axis=2) > 8).sum())
print(f"{'PASS' if moved else 'FAIL'} P0 output live during the run: "
      f"{moved} px changed between the two control frames")
if not moved:
    sys.exit(1)

# Whatever churns in the dock band with NOTHING minimized cannot be a preview:
# the second fixture stays visible all run and its blur can bleed under the pill.
noise = np.abs(pre1[band] - pre0[band]).sum(axis=2) > 8
for _ in range(3):  # churn never lands twice on the same pixel; grow the mask
    noise[1:] |= noise[:-1]
    noise[:-1] |= noise[1:]
    noise[:, 1:] |= noise[:, :-1]
    noise[:, :-1] |= noise[:, 1:]
print(f"noise mask (nothing minimized, frame to frame): {int(noise.sum())} px excluded")


def largest_blob(mask):
    seen = np.zeros_like(mask)
    best = []
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
        if len(px) > len(best):
            best = px
    return best


# P1. LIVE: every consecutive pair must differ inside the pill. Four pairs at
# 0.8s against a 1s half-cycle cannot all land on the same phase, so a frozen
# preview has nowhere to hide.
boxes, ok1 = [], True
for i in range(4):
    diff = (np.abs(live[i + 1][band] - live[i][band]).sum(axis=2) > 8) & ~noise
    blob = largest_blob(diff)
    if not blob:
        print(f"FAIL P1 live{i} vs live{i + 1}: nothing changed -- the preview is FROZEN")
        ok1 = False
        continue
    ys = np.array([p[0] for p in blob])
    xs = np.array([p[1] for p in blob])
    box = (int(xs.min()), int(ys.min()) + H - BAND, int(xs.max() - xs.min() + 1), int(ys.max() - ys.min() + 1))
    boxes.append(box)
    print(f"     live{i} vs live{i + 1}: blob {len(blob)} px  x,y,w,h = {box}")
print(f"{'PASS' if ok1 else 'FAIL'} P1 the preview repaints between consecutive frames")

# P2. It is the WINDOW, at the size the layout says -- not an icon, not a thumb
# of some other shape. Predicted from the real window size and monitor scale.
scale = mon["scale"]
win = next(c for c in clients if c["class"] == "x25flip")
aspect = min(MAX_ASPECT, max(MIN_ASPECT, win["size"][0] / win["size"][1]))
want_h = round(ICON * scale)
want_w = round(ICON * aspect * scale)
TOL = 3
ok2 = bool(boxes) and all(abs(b[2] - want_w) <= TOL and abs(b[3] - want_h) <= TOL for b in boxes)
print(f"window {win['size']}  aspect {aspect:.2f}  scale {scale}")
print(f"{'PASS' if ok2 else 'FAIL'} P2 preview is {want_w}x{want_h} px "
      f"(icon row height x clamped window aspect, tol {TOL}px)")

# P3. It is the REAL surface, live: the fixture only ever paints #e01010 or
# #1010e0, so the preview's own pixels must be one of those, and the two frames
# either side of a change must not be the same one.
def hue(frame, box):
    x, y, w, h = box
    patch = frame[y + h // 3:y + 2 * h // 3, x + w // 3:x + 2 * w // 3].reshape(-1, 3)
    return "red" if patch[:, 0].mean() > patch[:, 2].mean() else "blue"


hues = [hue(live[i], boxes[0]) for i in range(5)] if boxes else []
ok3 = len(set(hues)) == 2
print(f"{'PASS' if ok3 else 'FAIL'} P3 preview shows the fixture's own repaints: {hues}")

sys.exit(0 if (ok1 and ok2 and ok3) else 1)
