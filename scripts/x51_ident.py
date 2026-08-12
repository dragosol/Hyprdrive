#!/usr/bin/env python3
"""X51: is the cached-glyph render PIXEL-IDENTICAL to the cold one?

    x51_ident.py A.png B.png C.png [layers.json]

A  the first overview open after a compositor restart -- every string cold
B  a later open -- every string served from the surviving glyph cache
C  B plus a typed query. A MUST-DIFFER control: two identical frames are also
   what a starved output produces, and then A==B would prove nothing.

WHY THIS IS NOT `cmp -s A B` ANY MORE (2026-08-12)
--------------------------------------------------
It was, and the gate had been red on it. The frames are whole-output grabs, and
this output carries the quickshell bar -- a layer surface with a clock and CPU,
RAM and temperature readouts that tick on their own. A and B are taken about
twenty seconds apart (four open/close laps in between), so a readout moves
between them essentially always. Measured on the frames from the 2026-08-12
suite run: A and B differ by 106 pixels, ALL of them inside x 800..916,
y 10..25 -- the bar's clock. Not one differing pixel anywhere the plugin draws.

So the bar comes out, and it comes out the way g1's grader does it: every
non-fullscreen layer-shell surface on the graded output, read from
`hyprctl layers -j` which the rig dumps beside the frames. The fullscreen
background layer is NOT masked -- that is the wallpaper the overview is drawn
over, and masking it would mask the claim.

AND THE OTHER CLOCK (2026-08-12, the second half of the same bug)
-----------------------------------------------------------------
Masking the bar left x51 a straddler: PASS in one suite, FAIL in the next, same
build. The ii DESKTOP CLOCK widget is drawn INSIDE that fullscreen background
layer, so `layers.json` cannot describe it, and it shows through the overview's
wallpaper backdrop. It is an analog face with the hour and minute set in
digits, and A and B are about twenty-five seconds apart -- so a minute boundary
lands between them roughly a third of the time, and when it does the frames
differ by ~1700 px of clock and nothing else.

Measured on the frames of the run that failed (zrig/danglingA2/x51-diffzone-*.png,
kept): A reads 18:38, B reads 18:39, 1675 differing pixels, all inside
x 1629..1722 y 528..588, and not one differing pixel anywhere the plugin draws.
The widget's own extent on this output is x 1596..1784, y 445..630 -- measured
by saturation, because wp17 is fully greyscale and the widget is the only
coloured thing over the wallpaper.

So its box is pinned below, padded, and LEASHED at 1.5% of the frame: a
hand-written mask is the one place this gate could be made to pass by hiding
the failure, so that is where the limit goes.

What is left is graded EXACTLY. The claim is "pixel-identical", so the
threshold is zero differing pixels, not a tolerance.
"""

# The ii desktop clock widget, measured on Virtual-1 at 2560x1600 on
# 2026-08-12: the face occupies x 1596..1784, y 445..630. Padded by ~16 px,
# because what moves is INSIDE the face (hands, digits) and the face itself has
# not moved between any two frames measured here.
CLOCK_BOX = (1580, 429, 220, 217)   # x, y, w, h  -- 1.17% of a 2560x1600 frame
CLOCK_REF = (2560, 1600)            # the frame size that box was measured on
import json
import pathlib
import sys

import numpy as np
from PIL import Image


def load(p):
    return np.asarray(Image.open(p).convert("RGB")).astype(np.int16)


def chrome_mask(layers_path, shape):
    """True where a layer-shell surface that is not the wallpaper is drawn."""
    h, w = shape
    m = np.zeros((h, w), bool)
    notes = []
    p = pathlib.Path(layers_path) if layers_path else None
    if not p or not p.exists():
        notes.append("NO layers.json -- the bar is NOT masked and its clock will decide this")
        p = None
    for _mon, v in (json.loads(p.read_text()).items() if p else ()):
        for _lvl, surfaces in v.get("levels", {}).items():
            for s in surfaces:
                if s["w"] * s["h"] >= 0.5 * w * h:
                    continue
                x0, y0 = max(0, s["x"]), max(0, s["y"])
                x1, y1 = min(w, s["x"] + s["w"]), min(h, s["y"] + s["h"])
                if x1 > x0 and y1 > y0:
                    m[y0:y1, x0:x1] = True
                    notes.append(f"{s['namespace']} {s['w']}x{s['h']}@{s['x']},{s['y']}")

    cx, cy, cw, ch = CLOCK_BOX
    sx, sy = w / CLOCK_REF[0], h / CLOCK_REF[1]
    x0, y0 = int(cx * sx), int(cy * sy)
    x1, y1 = min(w, int((cx + cw) * sx)), min(h, int((cy + ch) * sy))
    m[y0:y1, x0:x1] = True
    pinned = (x1 - x0) * (y1 - y0)
    notes.append(f"desktop clock {x1-x0}x{y1-y0}@{x0},{y0}  (PINNED, hand-written)")
    return m, notes, pinned


def main(argv):
    A, B, C = (load(argv[i]) for i in (1, 2, 3))
    if not (A.shape == B.shape == C.shape):
        print("FAIL: the three frames are different sizes")
        return 1
    h, w = A.shape[:2]
    mask, notes, pinned = chrome_mask(argv[4] if len(argv) > 4 else None, (h, w))
    pct = 100.0 * mask.sum() / (h * w)
    ppct = 100.0 * pinned / (h * w)
    print(f"frame {w}x{h}   chrome masked {mask.sum()} px = {pct:.2f}%  (pinned {ppct:.2f}%)")
    for n in notes:
        print(f"  masked: {n}")
    # The leash goes on the hand-written box, not on the compositor's own report
    # of what another process draws here: the pinned box is the only part of
    # this mask that could be grown to make a failing gate pass.
    if ppct > 1.5:
        print(f"FAIL: the pinned clock box is {ppct:.2f}% of the frame -- a hand-written "
              "mask that big can hide the difference this gate exists to find")
        return 1
    if pct > 8.0:
        print("FAIL: too much of the output is somebody else's chrome to judge this")
        return 1
    keep = ~mask

    ab_raw = int((np.abs(A - B).max(axis=2) > 0).sum())
    ab = int(((np.abs(A - B).max(axis=2) > 0) & keep).sum())
    bc = int(((np.abs(B - C).max(axis=2) > 8) & keep).sum())
    print(f"A vs B   {ab_raw} px differ over the whole frame, {ab} of them outside the chrome")
    print(f"B vs C   {bc} px differ outside the chrome  (must-differ control)")

    if bc < 10000:
        print("VOID: the typed-query control did not move -- the output was starved, "
              "so A == B would prove nothing")
        return 1
    if ab:
        ys, xs = np.where((np.abs(A - B).max(axis=2) > 0) & keep)
        print(f"FAIL: cold text (A) != cached text (B) -- {ab} px differ, "
              f"bbox x {xs.min()}..{xs.max()} y {ys.min()}..{ys.max()}")
        return 1
    print("X51 PASS: the glyph-cache-served render is pixel-identical to the cold one, "
          "and the typed-query control proves the output was live")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
