#!/usr/bin/env python3
"""E8-f gate. Runs on the HOST (the guest has no PIL) against the captures
e8f_probe2.sh leaves in the shared folder.

E8-f is exactly the statement "the strip after a drop differs from the strip
after closing and reopening" -- reopening was the user's workaround, not a fix.
So this asserts two things: every dropped window's mini is FILLED rather than an
outline (an outline-only mini scores ~0 of its colour), and the post-drop strip
matches the reopened one.
"""
import sys
from PIL import Image
import numpy as np

TAG = sys.argv[1] if len(sys.argv) > 1 else "gate"
DIR = "/home/dragos/hyprvm/share/e8f"


def fills(path):
    a = np.array(Image.open("%s/%s" % (DIR, path)).convert("RGB")).astype(int)
    b = a[190:320, :]
    r, g, bl = b[:, :, 0], b[:, :, 1], b[:, :, 2]
    return {
        "red":    int(((r > 150) & (g < 70) & (bl < 70)).sum()),
        "yellow": int(((r > 170) & (g > 170) & (bl < 90)).sum()),
        "green":  int(((g > 150) & (r < 80) & (bl < 80)).sum()),
        "blue":   int(((bl > 150) & (r < 70) & (g < 70)).sum()),
    }


after = fills("%s-B-t3.png" % TAG)
reopened = fills("%s-reopened.png" % TAG)
print("after drop :", after)
print("reopened   :", reopened)

fail = False
for k in after:
    if after[k] < 500:
        print("FAIL: %s mini is outline-only after the drop (%d px)" % (k, after[k]))
        fail = True
    if abs(after[k] - reopened[k]) > max(200, reopened[k] // 10):
        print("FAIL: %s differs after drop vs reopened (%d vs %d)" % (k, after[k], reopened[k]))
        fail = True

print("E8F_GATE_FAIL" if fail else "E8F_GATE_PASS")
sys.exit(1 if fail else 0)
