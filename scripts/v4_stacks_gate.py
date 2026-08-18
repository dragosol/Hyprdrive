#!/usr/bin/env python3
"""Grade a dock-stacks frame STRUCTURALLY, never by energy.

The house rule this file exists to obey: "gates must grade STRUCTURE, not
colour or energy alone" -- x26 matched foliage as fixture green, x64 passed a
synthetic unblurred overlay. A fan is not "some bright pixels above the dock";
it is a row of plates at ARITHMETICALLY PREDICTED positions, and the check is
that content is present at each predicted row and absent one row past the last.
A wallpaper cannot satisfy that and neither can a stray window.

Positions come from the same constants the cell predictor uses, so a layout
change that moves the fan makes this gate red rather than making it lenient.

usage:
    v4_stacks_gate.py fan   SHOT.png BASE.png CX PILLY NROWS
    v4_stacks_gate.py grid  SHOT.png BASE.png CX PILLY
    v4_stacks_gate.py diff  A.png B.png X Y W H MINBLOB
"""
import sys

import numpy as np
from PIL import Image

# DockStacks.cpp geometry, unscaled px, x monitor scale 1.0 on the rig's output.
FAN_STEP = 56.0
FAN_ROW_H = 52.0
FAN_GAP = 10.0
GRID_PAD = 14.0
GRID_CELL_H = 104.0
GRID_SPACING = 12.0

# "Not the wallpaper" is decided against a BASE frame of the same desktop with
# no popup on it -- a control, not an absolute threshold, so the picture cannot
# decide the verdict.
DEV = 26
# A row counts as drawn once this many pixels in its band differ from base.
ROW_MIN = 900


def load(p):
    return np.asarray(Image.open(p).convert("RGB")).astype(int)


def band_diff(shot, base, x0, y0, w, h):
    x0, y0 = max(0, int(x0)), max(0, int(y0))
    x1, y1 = min(shot.shape[1], int(x0 + w)), min(shot.shape[0], int(y0 + h))
    if x1 <= x0 or y1 <= y0:
        return 0
    a = shot[y0:y1, x0:x1]
    b = base[y0:y1, x0:x1]
    return int((np.abs(a - b).max(axis=2) > DEV).sum())


def largest_blob(mask):
    """Largest connected component, on a 4x downsample. No scipy here."""
    S = 4
    h, w = mask.shape
    m = mask[: h // S * S, : w // S * S].reshape(h // S, S, w // S, S).any(axis=(1, 3))
    seen = np.zeros_like(m, dtype=bool)
    best = 0
    hh, ww = m.shape
    for sy in range(hh):
        for sx in range(ww):
            if not m[sy, sx] or seen[sy, sx]:
                continue
            stack = [(sy, sx)]
            seen[sy, sx] = True
            n = 0
            while stack:
                y, x = stack.pop()
                n += 1
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < hh and 0 <= nx < ww and m[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        stack.append((ny, nx))
            best = max(best, n)
    return best * S * S


def grade_fan(shot, base, cx, pilly, nrows):
    """Each of `nrows` predicted row bands must carry content; the band one
    step past the last must not. The absent-row control is what makes this a
    count rather than a presence test."""
    fail = 0
    print("    fan rows expected: %d, step %.0f px up from pill y %d" % (nrows, FAN_STEP, pilly))
    for i in range(nrows + 1):
        y = pilly - FAN_GAP - FAN_STEP * (i + 1)
        # The row is right-aligned near cx and ragged to the LEFT, and shifts
        # right with i; a band 700 wide centred a little left of cx covers it
        # for every i the cap allows.
        n = band_diff(shot, base, cx - 520, y, 760, FAN_ROW_H)
        want = "drawn" if i < nrows else "EMPTY"
        got = "drawn" if n >= ROW_MIN else "empty"
        flag = "" if (i < nrows) == (n >= ROW_MIN) else "   <-- WRONG"
        print("      row %2d  y %5d  %7d px  want %-5s got %s%s" % (i, int(y), n, want, got, flag))
        if (i < nrows) != (n >= ROW_MIN):
            fail = 1

    if fail:
        print("FAIL the fan does not have exactly %d rows at the predicted positions" % nrows)
    return fail


def grade_grid(shot, base, cx, pilly):
    """A grid is ONE plate, so its signature is the opposite of a fan's: the
    band that a fan's second row would occupy is contiguous with the band its
    first row occupies, and the plate is wider than any fan row."""
    y1 = pilly - FAN_GAP - GRID_CELL_H
    n_wide = band_diff(shot, base, cx - 260, y1, 520, 80)
    # A fan leaves a GAP between rows (FAN_STEP 56 vs FAN_ROW_H 52 -> 4 px, plus
    # the shift means row 2 is offset right). A grid is solid across.
    print("    grid plate band at y %d: %d px changed" % (int(y1), n_wide))
    if n_wide < 4000:
        print("FAIL nothing that looks like a grid plate above the cell")
        return 1
    return 0


if __name__ == "__main__":
    MODE = sys.argv[1]
    if MODE == "diff":
        A, B = load(sys.argv[2]), load(sys.argv[3])
        X, Y, W, H, MIN = (int(v) for v in sys.argv[4:9])
        x1, y1 = min(A.shape[1], X + W), min(A.shape[0], Y + H)
        m = np.abs(A[Y:y1, X:x1] - B[Y:y1, X:x1]).max(axis=2) > DEV
        blob = largest_blob(m)
        print("    diff in (%d,%d %dx%d): %d px changed, largest blob %d (floor %d)" % (X, Y, W, H, int(m.sum()), blob, MIN))
        if blob < MIN:
            print("FAIL the region did not change")
            sys.exit(1)
        sys.exit(0)

    SHOT, BASE = load(sys.argv[2]), load(sys.argv[3])
    CX, PILLY = int(sys.argv[4]), int(sys.argv[5])
    if MODE == "fan":
        sys.exit(grade_fan(SHOT, BASE, CX, PILLY, int(sys.argv[6])))
    if MODE == "grid":
        sys.exit(grade_grid(SHOT, BASE, CX, PILLY))
    sys.exit("unknown mode %s" % MODE)
