"""G1 gate. Runs on the HOST -- the guest has no numpy or PIL.

Every assertion is a frame diff, because G1's claim is about a keystroke that
must change nothing. Two of the six frames MUST move, and they are what stops a
frozen output from passing: an output that hands back one frame forever fails
20-typed and 40-k_x rather than sailing through the no-op checks.
"""
import sys
import numpy as np
from PIL import Image

OUT = "/home/dragos/hyprvm/share/g1"
TAG = sys.argv[1]

# A frame is 2560x1600; virgl reproduces a static scene exactly, so the tolerance
# is for nothing but stray cursor/AA pixels.
NOISE = 400


def px(name):
    return np.asarray(Image.open(f"{OUT}/{TAG}-{name}.png").convert("RGB")).astype(int)


def diff(a, b):
    return int((np.abs(px(a) - px(b)).max(axis=2) > 8).sum())


ctrlA_space = diff("00-ctrlA", "10-space")
ctrlA_ctrlB = diff("00-ctrlA", "01-ctrlB")
ctrlA_typed = diff("00-ctrlA", "20-typed")
kx_k_x = diff("30-kx", "40-k_x")

rows = [
    ("SPACE on an empty query is a no-op", "ctrlA vs 10-space", ctrlA_space, ctrlA_space <= NOISE),
    ("no drift between two idle frames", "ctrlA vs 01-ctrlB", ctrlA_ctrlB, ctrlA_ctrlB <= NOISE),
    ("LIVENESS: 'k' does start a search", "ctrlA vs 20-typed", ctrlA_typed, ctrlA_typed > NOISE),
    ("SPACE types once a search is active", "30-kx vs 40-k_x", kx_k_x, kx_k_x > NOISE),
]

print(f"{'claim':44} {'frames':22} {'changed px':>11}  verdict")
for claim, frames, n, ok in rows:
    print(f"{claim:44} {frames:22} {n:>11}  {'PASS' if ok else 'FAIL'}")

sys.exit(0 if all(r[3] for r in rows) else 1)
