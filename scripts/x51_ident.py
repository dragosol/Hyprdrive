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

What is left is graded EXACTLY. The claim is "pixel-identical", so the
threshold is zero differing pixels, not a tolerance.
"""
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
        return m, ["NO layers.json -- nothing masked, the bar's clock will decide this"]
    for _mon, v in json.loads(p.read_text()).items():
        for _lvl, surfaces in v.get("levels", {}).items():
            for s in surfaces:
                if s["w"] * s["h"] >= 0.5 * w * h:
                    continue
                x0, y0 = max(0, s["x"]), max(0, s["y"])
                x1, y1 = min(w, s["x"] + s["w"]), min(h, s["y"] + s["h"])
                if x1 > x0 and y1 > y0:
                    m[y0:y1, x0:x1] = True
                    notes.append(f"{s['namespace']} {s['w']}x{s['h']}@{s['x']},{s['y']}")
    return m, notes


def main(argv):
    A, B, C = (load(argv[i]) for i in (1, 2, 3))
    if not (A.shape == B.shape == C.shape):
        print("FAIL: the three frames are different sizes")
        return 1
    h, w = A.shape[:2]
    mask, notes = chrome_mask(argv[4] if len(argv) > 4 else None, (h, w))
    pct = 100.0 * mask.sum() / (h * w)
    print(f"frame {w}x{h}   chrome masked {mask.sum()} px = {pct:.2f}%")
    for n in notes:
        print(f"  masked: {n}")
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
