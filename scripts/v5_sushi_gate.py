#!/usr/bin/env python3
"""Graders for the V5 spacebar-preview gates.

Two things the other graders in this tree do not do:

FROST IS A THREE-FRAME A/B, and its threshold is low on purpose. A frosted
window shows the blur of what is behind it THROUGH ITS OWN TRANSPARENCY, and
that transparency is 0.92 -- so the whole visible difference between "blur on"
and "blur off" is eight percent of the difference between a blurred and an
unblurred backdrop. Measured on the guest with a preview up over the pinned
wallpaper: 46694 px changed at threshold 3, and a maximum per-pixel delta of
FOURTEEN. The DEV=26 every other gate in this tree uses would have reported
zero changed pixels and called a correctly frosted window opaque.

What makes a threshold of 3 safe is not luck, it is the control: two grabs of
the same static scene on the headless output are BIT-IDENTICAL -- 0 px at
threshold 3, maximum delta 0 -- so this grader asserts that control rather than
assuming it. If the session ever becomes noisy enough to matter, the control
reds and the verdict is withheld instead of being read off the noise.

The frames are A1 (blur on), B (blur off), A2 (blur on again): controls on BOTH
sides of the measured frame, per the standing doctrine. A1 vs A2 is the noise
floor AND the proof that turning blur back on restored the picture; A1 vs B and
B vs A2 must BOTH be large, so a frozen capture -- which would make all three
identical -- fails explicitly rather than passing as "no noise at all".

And the change must be CONFINED: an OUT region of bare wallpaper, nowhere near
the window or the dock, must not change when blur is switched off. That is what
makes this a measurement of the WINDOW rather than of a global repaint, and it
is the same lesson x26 and x64 are on record for -- if a picture can decide the
verdict, the picture is what is being graded.

usage:
    v5_sushi_gate.py frost A1 B A2 X Y W H OUTX OUTY OUTW OUTH
    v5_sushi_gate.py same  A B X Y W H MAXBLOB
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from blob import largest_of  # noqa: E402

# The frost threshold, and why it is not 26 -- see the module docstring.
FROST_DEV = 3
# The control must be quieter than this, or nothing below it is trustworthy.
CONTROL_MAX = 200
# Blur has to move at least this much of the window, as one connected blob --
# a FRACTION of the graded box, because how much of a window the blur reaches is
# not a constant: it depends on how much detail is behind it and on how big it
# is. Measured on two different previews over the same wallpaper: 5.6% of the
# box for a 684x551 window, 2.5% for a 544x452 one. A fixed floor calibrated on
# the first is a threshold straddler for the second, which is the x26 P4 mistake
# and it is not repeated here.
#
# The floor is generous ON PURPOSE. It is a LIVENESS floor, not a discrimination
# one: the thing this separates frosted from is OPAQUE, and an opaque window
# measures exactly ZERO -- there is nothing behind it showing through for the
# blur pass to reach, and the control proves zero is what a still scene gives.
# So the honest floor is "well clear of nothing", not "just under what a good
# build happens to produce".
FROST_MIN_FRAC = 0.004
FROST_MIN_BLOB = 1000
# The bare-wallpaper control must be quieter than this.
OUT_MAX = 200

# The ordinary threshold, for the ordinary question ("did this region change").
DEV = 26


def load(p):
    return np.asarray(Image.open(p).convert("RGB")).astype(int)


def crop(a, x, y, w, h):
    x0, y0 = max(0, int(x)), max(0, int(y))
    x1, y1 = min(a.shape[1], int(x + w)), min(a.shape[0], int(y + h))
    return a[y0:y1, x0:x1]


def mask_of(a, b, x, y, w, h, dev):
    return np.abs(crop(a, x, y, w, h) - crop(b, x, y, w, h)).max(axis=2) > dev


def dilate(mask):
    """One-cell dilation -- the doctrine's noise-mask widening. No scipy here."""
    out = mask.copy()
    out[1:, :] |= mask[:-1, :]
    out[:-1, :] |= mask[1:, :]
    out[:, 1:] |= mask[:, :-1]
    out[:, :-1] |= mask[:, 1:]
    return out


def area(mask):
    found = largest_of(mask)
    return found[4] if found else 0


def grade_frost(a1, b, a2, box, outbox):
    x, y, w, h = box
    fail = 0

    noise = mask_of(a1, a2, x, y, w, h, FROST_DEV)
    print("    control  A1 vs A2 (blur on, twice): %d px over threshold %d (ceiling %d)"
          % (int(noise.sum()), FROST_DEV, CONTROL_MAX))
    if int(noise.sum()) > CONTROL_MAX:
        print("FAIL the session is not still enough to grade frost at this threshold")
        fail = 1

    # The noise mask, DILATED, comes out of BOTH measured masks: a pixel that
    # moves on its own is not evidence of blur, whichever frame it turns up in.
    quiet = ~dilate(noise)

    m_ab = mask_of(a1, b, x, y, w, h, FROST_DEV) & quiet
    m_ba = mask_of(b, a2, x, y, w, h, FROST_DEV) & quiet
    n_ab, n_ba = area(m_ab), area(m_ba)
    floor = max(FROST_MIN_BLOB, int(FROST_MIN_FRAC * m_ab.size))
    print("    measured A1 vs B  (blur on vs OFF): %7d px changed, largest blob %7d (floor %d = %.1f%% of the box)"
          % (int(m_ab.sum()), n_ab, floor, 100.0 * floor / max(1, m_ab.size)))
    print("    measured B  vs A2 (blur OFF vs on): %7d px changed, largest blob %7d (floor %d)"
          % (int(m_ba.sum()), n_ba, floor))

    if n_ab < floor or n_ba < floor:
        print("FAIL switching blur off did not change the preview window -- it is not frosted")
        print("     (an OPAQUE window measures exactly this: there is nothing showing through")
        print("      it for the blur pass to reach, so turning blur off changes nothing)")
        fail = 1

    ox, oy, ow, oh = outbox
    out = mask_of(a1, b, ox, oy, ow, oh, FROST_DEV)
    print("    confined OUT (bare wallpaper at %d,%d %dx%d): %d px changed (ceiling %d)"
          % (ox, oy, ow, oh, int(out.sum()), OUT_MAX))
    if int(out.sum()) > OUT_MAX:
        print("FAIL turning blur off changed the bare desktop as well, so what is graded")
        print("     above is a repaint and not this window")
        fail = 1

    return fail


def grade_same(a, b, box, maxblob):
    x, y, w, h = box
    m = mask_of(a, b, x, y, w, h, DEV)
    n = area(m)
    print("    unchanged (%d,%d %dx%d): %d px differ, largest blob %d (ceiling %d)"
          % (x, y, w, h, int(m.sum()), n, maxblob))
    if n > maxblob:
        print("FAIL the region was supposed to be untouched and it moved")
        return 1
    return 0


if __name__ == "__main__":
    MODE = sys.argv[1]
    if MODE == "frost":
        A1, B, A2 = load(sys.argv[2]), load(sys.argv[3]), load(sys.argv[4])
        BOX = tuple(int(v) for v in sys.argv[5:9])
        OUTBOX = tuple(int(v) for v in sys.argv[9:13])
        sys.exit(grade_frost(A1, B, A2, BOX, OUTBOX))
    if MODE == "same":
        A, B = load(sys.argv[2]), load(sys.argv[3])
        BOX = tuple(int(v) for v in sys.argv[4:8])
        sys.exit(grade_same(A, B, BOX, int(sys.argv[8])))
    sys.exit("unknown mode %s" % MODE)
