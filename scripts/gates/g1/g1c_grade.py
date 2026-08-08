#!/usr/bin/env python3
"""g1c grade -- G1's last clause (compose), same frame-diff scheme as g1_gate.py.

    g1c_grade.py <framedir> <tag>

No dedicated grader existed for g1c_rig.sh (its frames were graded ad hoc by
the same frame-diff scheme); this transcribes the rig's own header into
g1_gate.py's scheme verbatim (per-pixel channel diff > 8, NOISE = 400):

  no drift              00-ctrlA vs 01-ctrlB       <= NOISE
  the sequence COMPOSES 10-compose vs 20-raw       >  NOISE  (identical would
                        mean `Compose ' e` passed through as the raw "'e")
  compose TYPED at all  00-ctrlA vs 10-compose     >  NOISE  (a swallowed
                        sequence leaves the query empty and 10 == ctrlA)
  Compose alone ACTIVATES 30-desktop vs 40-composeEsc > NOISE (the first ESC
                        only CLEARS, so frame 40 must still look OPEN)
  ESC-close control     30-desktop vs 50-escClose  <= NOISE  (with no search
                        active the first ESC closes; 50 must look like desktop)

A frozen output hands back one frame forever; it fails the three must-differ
rows rather than sailing through the must-match ones.
"""
import sys
import numpy as np
from PIL import Image

OUT = sys.argv[1]
TAG = sys.argv[2]
NOISE = 400   # same tolerance as g1_gate.py: stray cursor/AA pixels only


def px(name):
    return np.asarray(Image.open(f"{OUT}/{TAG}-{name}.png").convert("RGB")).astype(int)


def diff(a, b):
    return int((np.abs(px(a) - px(b)).max(axis=2) > 8).sum())


drift = diff("00-ctrlA", "01-ctrlB")
comp_raw = diff("10-compose", "20-raw")
typed = diff("00-ctrlA", "10-compose")
opened = diff("30-desktop", "40-composeEsc")
closed = diff("30-desktop", "50-escClose")

rows = [
    ("no drift between two idle frames", "ctrlA vs 01-ctrlB", drift, drift <= NOISE),
    ("compose differs from raw passthrough", "10-compose vs 20-raw", comp_raw, comp_raw > NOISE),
    ("compose typed something at all", "ctrlA vs 10-compose", typed, typed > NOISE),
    ("Compose alone leaves ESC a query to clear", "30-desktop vs 40-composeEsc", opened, opened > NOISE),
    ("control: no search -> first ESC closes", "30-desktop vs 50-escClose", closed, closed <= NOISE),
]

print(f"{'claim':44} {'frames':28} {'changed px':>11}  verdict")
for claim, frames, n, ok in rows:
    print(f"{claim:44} {frames:28} {n:>11}  {'PASS' if ok else 'FAIL'}")

sys.exit(0 if all(r[3] for r in rows) else 1)
