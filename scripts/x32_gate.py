#!/usr/bin/env python3
"""X32: a fresh open from the dock's Show Applications button starts CLEAN.

Grades the four frames x32_rig.sh captures, and (with --tile) doubles as the
tile locator the rig aims its closing click with -- the same blob, so the click
and the verdict cannot disagree about where the fixture tile is.

    x32_gate.py --tile <c0.png>      -> prints "X Y", the tile's click point
    x32_gate.py <dir> <tag>          -> grades, exit 0 iff green

Claims, in the order they have to hold:

  NODRIFT  c0 vs c1, two idle frames of the same clean overview. This run's
           noise floor. Zero would be suspicious rather than good -- an output
           that hands back a frozen frame scores zero on everything -- so LIVE
           below is what proves the pipeline moved at all.
  LIVE     c0 vs q. The query has to be VISIBLE, or the rest of the gate is
           comparing two frames that were always going to match.
  CLEAN    c0 vs d. The button-opened overview must be the unfiltered one --
           within this run's drift, or 2% of LIVE, whichever is kinder. Every
           number here is the largest connected blob of changed pixels after the
           noise mask is dilated, never a bounding box.
           Measured 2026-08-11: 740254 px on the unfixed build, 661 on the fixed
           one, against a 115-139 px floor.
  DISTINCT d vs q, measured against LIVE rather than against the floor. If the
           button opened a clean overview, d differs from q by about as much as
           c0 does -- so the bar is "at least half of LIVE". A fixed absolute
           bar was tried first and is wrong: on the unfixed build d and q are
           the same frame plus a few thousand pixels of settling, which sits
           within noise of any threshold small enough to be meaningful.
"""
import sys

import numpy as np
from PIL import Image

FIXTURE = (255, 0, 255)          # the rig's magenta kitty
COLOUR_TOL = 60
DILATE = 2                       # noise-mask dilation, in pixels
LIVE_ABS_MIN = 20000.0           # a visible query moves far more than this
CLEAN_FRAC = 0.02                # CLEAN may show at most this fraction of LIVE


def load(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.int16)


def dilate(mask, r):
    out = mask.copy()
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            out |= np.roll(np.roll(mask, dy, 0), dx, 1)
    return out


def label_largest(mask):
    """Largest 4-connected blob in `mask`, as (count, ys, xs). No scipy in the
    guest, so this is an explicit two-pass union-find over the True pixels."""
    h, w = mask.shape
    lab = np.zeros((h, w), dtype=np.int32)
    parent = [0]

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)

    ys, xs = np.nonzero(mask)
    for y, x in zip(ys, xs):
        up = lab[y - 1, x] if y else 0
        left = lab[y, x - 1] if x else 0
        if up and left:
            lab[y, x] = min(up, left)
            union(up, left)
        elif up or left:
            lab[y, x] = up or left
        else:
            parent.append(len(parent))
            lab[y, x] = len(parent) - 1

    if len(parent) == 1:
        return 0, None, None
    roots = np.zeros(len(parent), dtype=np.int32)
    for i in range(len(parent)):
        roots[i] = find(i)
    flat = roots[lab]
    counts = np.bincount(flat.ravel())
    counts[0] = 0
    best = int(counts.argmax())
    ys, xs = np.nonzero(flat == best)
    return int(counts[best]), ys, xs


def blob(a, b, noise=None):
    """Largest connected blob of change between two frames, in pixels."""
    diff = np.abs(a - b).max(axis=2) > 18
    if noise is not None:
        diff &= ~noise
    return label_largest(diff)[0]


def tile_point(path):
    """The fixture tile's click point: centre of the largest connected blob of
    fixture colour. A bbox centre would sit in the gap between two tiles the
    moment the fixture appears twice (it does -- the desktop strip draws a mini
    of the same window)."""
    px = load(path)
    mask = (np.abs(px - np.array(FIXTURE, dtype=np.int16)).max(axis=2) <= COLOUR_TOL)
    n, ys, xs = label_largest(mask)
    if n < 4000:
        sys.exit("x32: no fixture tile in %s (largest blob %d px)" % (path, n))
    return int(round(xs.mean())), int(round(ys.mean()))


def main():
    if sys.argv[1:2] == ["--tile"]:
        x, y = tile_point(sys.argv[2])
        print(x, y)
        return 0

    d, tag = sys.argv[1], sys.argv[2]
    f = {k: load("%s/%s-%s.png" % (d, tag, k)) for k in ("c0", "c1", "q", "d")}

    # The noise floor is taken from the two idle frames and DILATED, so a
    # one-pixel wobble of an antialiased edge cannot be counted as a change
    # somewhere else.
    noise = dilate(np.abs(f["c0"] - f["c1"]).max(axis=2) > 18, DILATE)

    drift = blob(f["c0"], f["c1"])
    live = blob(f["c0"], f["q"], noise)
    clean = blob(f["c0"], f["d"], noise)
    distinct = blob(f["q"], f["d"], noise)

    # Thresholds hang off LIVE -- the effect this gate actually measured on this
    # run -- and off the drift, whichever is the more forgiving. A pure
    # multiple of the drift was tried first and is brittle at both ends: the
    # drift is a few hundred pixels on a quiet run and tens of thousands when
    # the open animation has not finished, so the same multiple is either
    # unmeetable or meaningless depending on the second.
    floor = max(drift, 1)
    ok_live = live > max(LIVE_ABS_MIN, floor * 2)
    ok_clean = clean <= max(floor, live * CLEAN_FRAC)
    ok_dist = distinct >= live * 0.5

    print("%-9s %-28s %10s  %s" % ("claim", "frames", "blob px", "verdict"))
    print("%-9s %-28s %10d  %s" % ("NODRIFT", "c0 vs c1 (noise floor)", drift, "----"))
    print("%-9s %-28s %10d  %s" % ("LIVE", "c0 vs q  (query landed)", live, "PASS" if ok_live else "FAIL"))
    print("%-9s %-28s %10d  %s" % ("CLEAN", "c0 vs d  (button = fresh)", clean, "PASS" if ok_clean else "FAIL"))
    print("%-9s %-28s %10d  %s" % ("DISTINCT", "q  vs d  (d is not q)", distinct, "PASS" if ok_dist else "FAIL"))
    print("\nfloor %d px; LIVE must beat %.0f, CLEAN must stay under %.0f, DISTINCT must beat %.0f"
          % (drift, max(LIVE_ABS_MIN, floor * 2), max(floor, live * CLEAN_FRAC), live * 0.5))

    if ok_live and ok_clean and ok_dist:
        print("X32 GATE: PASS")
        return 0
    print("X32 GATE: FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
