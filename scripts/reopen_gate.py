#!/usr/bin/env python3
"""Host-side gate for share/reopen_rig.sh.

The claim is binary, so the measure is too: REVERSED is either the overview or
it is the bare desktop. Comparing it against BOTH references is what makes that
a measurement instead of an opinion -- a frame that merely "looks open" to me is
not evidence, but a frame that is 30x closer to OPEN than to SHUT is.

The pass also requires OPEN and SHUT to differ from each other. If they do not,
the output was starved and handed back the same frame three times, and the whole
run proves nothing -- which is a VOID, not a pass.
"""
import sys

import numpy as np
from PIL import Image

SHOTS = "/home/dragos/hyprvm/share/reopenshots"
THRESH = 18


def load(name):
    return np.asarray(Image.open(f"{SHOTS}/{name}.png").convert("RGB")).astype(np.int16)


def differing(a, b):
    return int((np.abs(a - b).max(axis=2) > THRESH).sum())


def main():
    op, op2, shut, rev = load("open"), load("open2"), load("shut"), load("reversed")

    spread = differing(op, shut)
    print(f"open vs shut:      {spread} px  (the overview's whole footprint)")
    if spread < 200000:
        print("VOID: open and shut are near-identical -- the output was starved, nothing was measured")
        return 1

    # What a plain open costs against a plain open, two cycles apart. This is
    # the noise floor the reversal has to be judged against: the overview does
    # not come back byte-identical from one cycle to the next, and charging that
    # drift to the reversal would be measuring the wrong thing.
    drift = differing(op, op2)
    print(f"open vs open2:     {drift} px  (cycle-to-cycle drift, the noise floor)")

    to_open2 = differing(rev, op2)
    to_shut = differing(rev, shut)
    print(f"reversed vs open2: {to_open2} px")
    print(f"reversed vs shut:  {to_shut} px")

    if to_open2 >= to_shut:
        print("FAIL: the tap during the close animation was swallowed -- the overview stayed shut")
        return 1

    # A reversal that merely got PART of the way back would sit between the two
    # references, so "closer to open" alone is not enough. It has to be within
    # the drift a plain open already shows, plus a margin for the extra cycle.
    if to_open2 > max(drift * 2, spread // 20):
        print(f"FAIL: reversed is {to_open2} px off a same-cycle plain open (drift is {drift}) -- the reversal did not finish")
        return 1

    print("PASS: a tap during the close animation brings the overview back, indistinguishable from a plain open")
    return 0


if __name__ == "__main__":
    sys.exit(main())
