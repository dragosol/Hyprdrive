#!/usr/bin/env python3
"""G5 gate -- two result layouts, with PER-PROVIDER caps. Runs on the HOST.

    g5_gate.py <tag>

Grades share/g5/<tag>-{00-a0,01-a1,1NN-tNN}.png.

  NODRIFT   a0 vs a1 near-identical -- a drifting output invalidates every diff.
  LIVE      at least one t-frame differs from a0. A stalled output hands back
            the same frame forever and every ratio below would pass on zeros.
            This is graded on the SAME frames the checks below read, which is
            the X47 lesson: a guard on a different capture path is not a guard.
  FOUND     a selection was located on some frame. Asserted before anything is
            derived from the selection boxes, so an empty run FAILS rather than
            scoring 0 distinct positions as "no growth".
  CAPS      >= 6 DISTINCT selection boxes across the walk. The old cap was 5
            SHARED between apps and providers, so no walk of any length could
            reach a sixth. Per-provider caps make 6 apps + 5 provider rows
            reachable.
  GRID      at least one selection is a CELL and at least one is a ROW: a cell
            is narrow and tall (< 25% of the overview's width, >= 1.8x the
            shortest selection's height), a row is wide and short. Both shapes
            must be present -- that is what "two layouts" means, and a build
            that drew everything as cells would be just as wrong as the parent.

The locator is the SELECTED item and only it: it is drawn modifyA(1.F) and is
the one OPAQUE accent rect on screen. Tolerance 3, not 16 -- the card's own
background is the INACTIVE colour at alpha 0.55 and lands within 16 of the
accent, so a loose mask returns the card merged with its selection (x49_gate.py
measured 1356x120 where a row is 28px). Intersected with the change-since-rest
mask because this theme's accent is a dark warm brown the wallpaper is full of.
"""
import sys
import pathlib
import numpy as np
from PIL import Image

OUT = pathlib.Path(__file__).resolve().parent / "g5"
S = 4                        # label on a 4x downsample; there is no scipy here
ACCENT = (0x50, 0x45, 0x36)  # general:col.active_border 77504536, alpha forced to 1
TAGS = [f"1{i:02d}-t{i:02d}" for i in range(1, 11)]

# A row is ~1664 logical px wide and a cell ~132, so any run wider than this is
# a real selection and anything thinner is a speck of matching wallpaper. Set
# well under a cell's rendered width (~108px at the rig's 0.82 scale) so the
# NARROW shape is findable at all -- a threshold tuned for rows would make the
# grid invisible and score a working build as unchanged.
MINRUN = 50


def load(tag, name):
    return np.asarray(Image.open(OUT / f"{tag}-{name}.png").convert("RGB")).astype(int)


def overview_extent(base):
    """(x, y, w, h) of the overview card: the largest non-black blob."""
    small = (base.mean(axis=2) > 22)[::S, ::S]
    seen = np.zeros_like(small)
    best = None
    for sy, sx in zip(*np.where(small)):
        if seen[sy, sx]:
            continue
        stack, comp = [(sy, sx)], []
        seen[sy, sx] = True
        while stack:
            y, x = stack.pop()
            comp.append((y, x))
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < small.shape[0] and 0 <= nx < small.shape[1] \
                        and small[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        ys, xs = np.array(comp).T
        box = (xs.min() * S, ys.min() * S,
               (xs.max() - xs.min() + 1) * S, (ys.max() - ys.min() + 1) * S, len(comp))
        if best is None or box[4] > best[4]:
            best = box
    return best


def longest_run(line):
    """(x0, length) of the longest contiguous True run in a boolean scanline."""
    xs = np.where(line)[0]
    if xs.size == 0:
        return (0, 0)
    breaks = np.where(np.diff(xs) > 1)[0]
    starts = np.concatenate(([0], breaks + 1))
    ends = np.concatenate((breaks, [xs.size - 1]))
    lens = ends - starts + 1
    i = int(np.argmax(lens))
    return (int(xs[starts[i]]), int(lens[i]))


def selection(frame, base):
    """The opaque accent rect, or None. Accepts BOTH shapes G5 can draw.

    Graded by the LONGEST CONTIGUOUS RUN per scanline, never by the extent of
    all matching pixels. The first draft used the extent and it was wrong on
    exactly the shape this gate exists to find: a selected CELL is 110px wide
    with its own 39px icon drawn on top, so the accent survives as two ~44px
    halves, and the extent then stretched from a stray matching pixel at x=556
    to another at x=1284 and reported the cell as 396..729px wide -- a number
    that grew as the selection walked right. A run is immune to that.
    """
    near = np.ones(frame.shape[:2], bool)
    for c in range(3):
        near &= np.abs(frame[:, :, c] - ACCENT[c]) < 3
    m = near & (np.abs(frame - base).max(axis=2) > 10)

    runs = [longest_run(m[y]) for y in range(m.shape[0])]
    dense = np.where(np.array([r[1] for r in runs]) > MINRUN)[0]
    if dense.size == 0:
        return None
    y0, y1 = int(dense[0]), int(dense[-1])
    # One selection, not a merged stack. A cell is ~64px tall at the rig's
    # scale and a row ~28px; anything past 100 is two things joined.
    if not (18 <= y1 - y0 + 1 <= 100):
        return None
    # The widest scanline is the selection's unobstructed edge: a cell's top
    # band above its icon, a row's band above its label.
    best = max(runs[y0:y1 + 1], key=lambda r: r[1])
    return (best[0], y0, best[1], y1 - y0 + 1)


def main(tag):
    a0, a1 = load(tag, "00-a0"), load(tag, "01-a1")
    H, W = a0.shape[:2]
    fails = []

    ext = overview_extent(a0)
    if not ext:
        print("EXTENT   no overview card found -- nothing below can be believed")
        print("G5 GATE: FAIL (EXTENT)")
        return 1
    OVX, OVY, OVW, OVH, _ = ext
    print(f"frame {W}x{H}   overview {OVW}x{OVH} at ({OVX},{OVY})")

    drift = (np.abs(a1 - a0).max(axis=2) > 10).sum()
    print(f"NODRIFT  a0 vs a1 changed {drift} px")
    if drift > W * H * 0.001:
        fails.append("NODRIFT")

    sels, live = {}, 0
    for name in TAGS:
        try:
            f = load(tag, name)
        except FileNotFoundError:
            continue
        live = max(live, int((np.abs(f - a0).max(axis=2) > 10).sum()))
        sels[name] = selection(f, a0)

    print(f"LIVE     largest t-frame diff vs a0 {live} px")
    if live < W * H * 0.01:
        fails.append("LIVE")

    for name in TAGS:
        s = sels.get(name)
        print(f"  {name}  " + ("none" if not s else f"sel x={s[0]} y={s[1]} {s[2]}x{s[3]}"))

    found = [s for s in sels.values() if s]
    if not found:
        print("FOUND    no selection on any frame -- the checks below have no input")
        print("G5 GATE: FAIL (FOUND, CAPS, GRID)")
        return 1

    # Positions, not identities: the walk may wrap, and a wrapped walk revisits
    # boxes it has already shown. Distinct boxes is the reachable-result count.
    distinct = sorted({s for s in found})
    print(f"CAPS     {len(found)} selections seen, {len(distinct)} distinct")
    for d in distinct:
        print(f"           {d[2]}x{d[3]} at ({d[0]},{d[1]})")
    if len(distinct) < 6:
        print("CAPS     no more than the old SHARED cap of 5 is reachable")
        fails.append("CAPS")

    shortest = min(d[3] for d in distinct)
    cells = [d for d in distinct if d[2] < OVW * 0.25 and d[3] >= shortest * 1.8]
    rows = [d for d in distinct if d[2] >= OVW * 0.55]
    print(f"GRID     shortest selection {shortest}px tall; {len(cells)} cell-shaped, {len(rows)} row-shaped")
    if not cells:
        print("GRID     nothing narrow-and-tall -- the apps are still a list")
        fails.append("GRID")
    if not rows:
        print("GRID     nothing wide -- the provider sections are not lists")
        fails.append("GRID")

    fails = sorted(set(fails))
    print(("G5 GATE: FAIL (" + ", ".join(fails) + ")") if fails else "G5 GATE: PASS")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "post"))
