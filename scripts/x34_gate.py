#!/usr/bin/env python3
"""OVERVIEW_CPP_SPEC 13.9 X34 hotkey overlay. Host-side analysis for
share/x34_rig.sh -- the guest has no numpy, so every pixel claim is made here.

The overlay is the first thing in this dock that appears and then LEAVES ON A
TIMER, so every measurement is a triple: a control frame before, the measured
frame, a control frame after the timeout. That shape is what catches the failure
this VM actually has -- a starved output hands back the same frame forever, and
a two-frame gate reads that as "the overlay correctly did nothing".

  overlay  -- the numbers appeared, and then went away again.
  count    -- how many distinct circles. Ten items get ten; an eleventh does not.
  ink      -- how wide each number's white glyph is. Slot ten draws `0`, which is
              wider than `1` and nothing like as wide as `10`.
"""
import sys

import numpy as np
from PIL import Image

SHOTS = "/home/dragos/hyprvm/share/x34shots"
THRESH = 18


def load(name):
    return np.asarray(Image.open(f"{SHOTS}/{name}.png").convert("RGB")).astype(np.int16)


def dilate(m, n=3):
    for _ in range(n):
        m = m | np.roll(m, 1, 0) | np.roll(m, -1, 0) | np.roll(m, 1, 1) | np.roll(m, -1, 1)
    return m


def mask(a, b, noise=None):
    d = np.abs(a - b).max(axis=2) > THRESH
    if noise is not None:
        d &= ~dilate(np.abs(noise[0] - noise[1]).max(axis=2) > THRESH)
    return d


def label(m):
    """Connected components, 8-connected, by repeated max-propagation. The crops
    here are a dock's worth of pixels, so the naive version is fast enough.

    ponytail: O(passes x area). If a future gate labels a whole screen, reach for
    scipy.ndimage.label instead of making this cleverer.
    """
    ids = np.where(m, np.arange(m.size).reshape(m.shape) + 1, 0)
    while True:
        prev = ids
        acc = ids
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                acc = np.maximum(acc, np.roll(np.roll(ids, dy, 0), dx, 1))
        ids = np.where(m, acc, 0)
        if np.array_equal(ids, prev):
            return ids


def blobs(m, minpx=40):
    """Left-to-right, each as (x0, y0, x1, y1, px, own_mask). The mask is the
    component itself and not its box: unrelated specks share a box corner, and a
    measurement taken over the box picks them up as if they were part of the
    glyph."""
    ids = label(m)
    out = []
    for v in np.unique(ids):
        if v == 0:
            continue
        sel = ids == v
        ys, xs = np.nonzero(sel)
        if len(ys) < minpx:
            continue
        out.append((int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max()), len(ys), sel))
    return sorted(out, key=lambda b: b[:4])


def crop(img, box):
    x0, y0, x1, y1 = (int(v) for v in box)
    return img[y0:y1 + 1, x0:x1 + 1]


def solid_region(m, frac=0.35):
    if m.sum() == 0:
        return None

    def run(sums):
        peak = int(np.argmax(sums))
        limit = sums[peak] * frac
        lo = hi = peak
        while lo > 0 and sums[lo - 1] >= limit:
            lo -= 1
        while hi < len(sums) - 1 and sums[hi + 1] >= limit:
            hi += 1
        return lo, hi

    y0, y1 = run(m.sum(axis=1))
    x0, x1 = run(m[y0:y1 + 1].sum(axis=0))
    return x0, y0, x1, y1


def cmd_pill(prefix):
    box = solid_region(mask(load(f"{prefix}_on"), load(f"{prefix}_e1"),
                            noise=(load(f"{prefix}_e0"), load(f"{prefix}_e1"))))
    if box is None:
        print("FAIL pill: no difference between dock on and dock off")
        return 1
    x0, y0, x1, y1 = box
    print(f"PILL x0={x0} y0={y0} x1={x1} y1={y1} w={x1-x0+1} h={y1-y0+1}")
    return 0


def overlay_mask(prefix, box):
    """Where the overlay is, measured against BOTH controls. A pixel only counts
    if it changed when the numbers arrived AND changed back when they left --
    a wallpaper that ticked over once satisfies one of those and neither the
    other."""
    c0, up, c1 = (crop(load(f"{prefix}_{n}"), box) for n in ("c0", "up", "c1"))
    return mask(up, c0) & mask(up, c1), c0, up, c1


def cmd_overlay(prefix, x0, y0, x1, y1):
    box = (x0, y0, x1, y1)
    m, c0, up, c1 = overlay_mask(prefix, box)
    drift = int(mask(c0, c1).sum())
    print(f"  control drift c0 vs c1 = {drift}px")
    if drift == 0 and int(mask(up, c0).sum()) == 0:
        print("FAIL overlay: every frame identical -- the output is stalled, not quiet")
        return 1
    found = blobs(m)
    print(f"  overlay pixels={int(m.sum())} blobs={len(found)}")
    for b in found:
        print(f"    blob x{b[0]}-{b[2]} y{b[1]}-{b[3]} px={b[4]}")
    if not found:
        print("FAIL overlay: nothing appeared when the shortcut was pressed")
        return 1
    # It left again: whatever the overlay drew must be gone from the after frame.
    left = int((mask(c1, c0) & m).sum())
    if left > m.sum() * 0.1:
        print(f"FAIL overlay: {left}px of the overlay still differ after the timeout")
        return 1
    print(f"PASS overlay: {len(found)} number(s) appeared and cleared after the timeout")
    return 0


def cmd_count(prefix, x0, y0, x1, y1, expect):
    m, _, _, _ = overlay_mask(prefix, (x0, y0, x1, y1))
    found = blobs(m)
    for b in found:
        print(f"    blob x{b[0]}-{b[2]} y{b[1]}-{b[3]} px={b[4]}")
    ok = len(found) == int(expect)
    print(f"{'PASS' if ok else 'FAIL'} count: {len(found)} circles, expected {expect}")
    return 0 if ok else 1


def cmd_ink(prefix, x0, y0, x1, y1):
    """The white glyph inside each circle, left to right. Slot ten draws `0`:
    wider than `1`, and nowhere near as wide as two glyphs would be."""
    m, _, up, _ = overlay_mask(prefix, (x0, y0, x1, y1))
    found = blobs(m)
    if len(found) < 10:
        print(f"FAIL ink: only {len(found)} circles to measure")
        return 1
    widths = []
    for bx0, by0, bx1, by1, _, own in found:
        # White pixels that TOUCH another white pixel. The circle's rim is
        # antialiased against whatever icon is behind it, so over a light icon it
        # leaves scattered single bright pixels that read as glyph; a stroke,
        # however thin, is always joined to itself. Eroding the circle instead
        # was the first cut and it ate the parts of `3`, `4` and `9` that reach
        # for the rim.
        cell = up[by0:by1 + 1, bx0:bx1 + 1]
        white = (cell.min(axis=2) > 150) & own[by0:by1 + 1, bx0:bx1 + 1]
        white &= (np.roll(white, 1, 0) | np.roll(white, -1, 0)
                  | np.roll(white, 1, 1) | np.roll(white, -1, 1))
        cols = np.nonzero(white.any(axis=0))[0]
        widths.append(int(cols.max() - cols.min() + 1) if len(cols) else 0)
    print(f"  glyph widths L->R: {widths}")
    one, ten = widths[0], widths[9]
    mid = max(widths[1:9])
    ok = ten > one and ten <= mid * 1.35
    print(f"  slot1('1')={one} slot10={ten} widest_single(2-9)={mid}")
    print(f"{'PASS' if ok else 'FAIL'} ink: slot 10 draws one wider glyph ('0'), not '1' and not '10'")
    return 0 if ok else 1


def cmd_showdock(prefix, x0, y0, x1, y1):
    """Autohidden dock, revealed by the shortcut alone, hidden again by the
    timeout. Measured over the pill's own box."""
    box = (x0, y0, x1, y1)
    hidden, shown, again = (crop(load(f"{prefix}_{n}"), box) for n in ("hidden", "shown", "again"))
    reveal = int(mask(shown, hidden).sum())
    back = int(mask(again, hidden).sum())
    area = hidden.shape[0] * hidden.shape[1]
    print(f"  reveal={reveal}px  after-timeout={back}px  of {area}px")
    if reveal == 0:
        print("FAIL showdock: the shortcut changed nothing -- dock never came up")
        return 1
    ok = reveal > area * 0.15 and back < reveal * 0.25
    print(f"{'PASS' if ok else 'FAIL'} showdock: shortcut raised the dock and the timeout put it back")
    return 0 if ok else 1


def cmd_off(prefix, x0, y0, x1, y1):
    """hot_keys false: the shortcut must draw NOTHING. `_live` is the same
    shortcut with the switch back on -- without it "nothing was drawn" and "the
    output stopped producing frames" are the same measurement."""
    box = (x0, y0, x1, y1)
    c0, up, c1, live = (crop(load(f"{prefix}_{n}"), box) for n in ("c0", "up", "c1", "live"))
    changed = int((mask(up, c0) & mask(up, c1)).sum())
    proof = int(mask(live, c1).sum())
    print(f"  overlay pixels with hot_keys=false: {changed}   with it back on: {proof}")
    if proof == 0:
        print("FAIL off: the output drew nothing with hot_keys back ON -- frames are stalled")
        return 1
    ok = changed == 0
    print(f"{'PASS' if ok else 'FAIL'} off: nothing drawn when hot_keys is false")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(globals()[f"cmd_{sys.argv[1]}"](*sys.argv[2:]))
