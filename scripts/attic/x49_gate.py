#!/usr/bin/env python3
"""X49 gate -- the results are WIDE and CATEGORISED. Runs on the HOST (guest has no numpy).

    x49_gate.py <tag>

Grades share/x49/<tag>-{00-a0,01-a1,1N-tN}.png.

  NODRIFT   a0 vs a1 near-identical -- a drifting output invalidates every diff.
  LIVE      at least one t-frame differs from a0 -- a STALLED output hands back
            the same frame forever and every check below would pass on zeros.
  WIDE      the selected row spans most of the overview: >= 55% of its width,
            reaching within 4% of its right edge. The pre-X49 panel is the
            search pill's width, ~22%, and fails this on its own.
  HEADER    the row STARTS indented from the overview's left edge by roughly the
            leading column the provider header lives in (168 logical px plus a
            card pad), rather than at the card edge -- and, decisively, it is
            LEFT of centre, which a pill-width centred panel never is.
  SECTIONS  walking TAB produces at least one step that is >=1.3x the smallest
            step. Inside a card rows step by ROWHL+ROWGAPL; crossing a card
            boundary also costs two paddings and the section gap. One flat panel
            has a constant step and cannot produce this.

The locator is the SELECTED row, and only the selected row: it is drawn
modifyA(1.F) and is the one OPAQUE accent rect on screen. It is intersected with
the change mask because this theme's accent is a dark warm brown that the
wallpaper is full of -- the same trap x48_gate.py documents.
"""
import sys
import pathlib
import numpy as np
from PIL import Image

OUT = pathlib.Path(__file__).resolve().parent / "x49"
S = 4                        # label on a 4x downsample; there is no scipy here
ACCENT = (0x50, 0x45, 0x36)  # general:col.active_border 77504536, alpha forced to 1
TAGS = [f"1{i}-t{i}" for i in range(1, 7)]


def load(tag, name):
    return np.asarray(Image.open(OUT / f"{tag}-{name}.png").convert("RGB")).astype(int)


def blobs(mask, limit=4):
    """(x, y, w, h, npx) of the biggest connected components, largest first."""
    small = mask[::S, ::S]
    seen = np.zeros_like(small)
    out = []
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
        out.append((xs.min() * S, ys.min() * S,
                    (xs.max() - xs.min() + 1) * S, (ys.max() - ys.min() + 1) * S,
                    len(comp) * S * S))
    out.sort(key=lambda b: -b[4])
    return out[:limit]


def selected_row(frame, base):
    """The opaque accent rect, or None. Accent AND changed-since-rest.

    Tolerance 3, not 16, and this is the whole locator. The panel's own
    background is the INACTIVE colour at alpha 0.55 and it lands within 16 of
    the accent, so a loose mask returns the CARD merged with the row: measured
    here, +-16 gave a 1356x120 blob where a row is 28px tall, and the width it
    reported was the card's. The selected row is the one rect drawn
    modifyA(1.F), so it is the accent EXACTLY; +-3 cuts the card away and the
    mask comes back exactly 28 rows tall on both builds.
    """
    near = np.ones(frame.shape[:2], bool)
    for c in range(3):
        near &= np.abs(frame[:, :, c] - ACCENT[c]) < 3

    m = near & (np.abs(frame - base).max(axis=2) > 10)

    # The LONGEST CONTIGUOUS RUN per scanline, not the extent of all matching
    # pixels, and not a fixed 150px floor. G5 gave the apps a GRID: a selected
    # CELL is ~110px wide with its own 39px icon drawn over it, so a 150px floor
    # cannot see it at all and the extent of what is left stretches to whatever
    # stray pixel also matched. This gate went blind to exactly the boundary its
    # SECTIONS check exists to find -- it read a constant 33px step on a build
    # with two cards, because the frames that crossed the boundary returned None.
    runs = []
    for y in range(m.shape[0]):
        xs = np.where(m[y])[0]
        if xs.size == 0:
            runs.append((0, 0))
            continue
        brk = np.where(np.diff(xs) > 1)[0]
        st = np.concatenate(([0], brk + 1))
        en = np.concatenate((brk, [xs.size - 1]))
        i = int(np.argmax(en - st + 1))
        runs.append((int(xs[st[i]]), int(en[i] - st[i] + 1)))

    dense = np.where(np.array([r[1] for r in runs]) > 50)[0]
    if dense.size == 0:
        return None
    y0, y1 = int(dense[0]), int(dense[-1])
    if not (18 <= y1 - y0 + 1 <= 100):  # one row or one cell, not a merged stack
        return None
    best = max(runs[y0:y1 + 1], key=lambda r: r[1])
    return (best[0], y0, best[1], y1 - y0 + 1, int(m.sum()))


def main(tag):
    a0, a1 = load(tag, "00-a0"), load(tag, "01-a1")
    H, W = a0.shape[:2]
    fails = []

    ov = blobs(a0.mean(axis=2) > 22, limit=1)
    if not ov:
        print("EXTENT   no overview card found -- nothing below can be believed")
        print("X49 GATE: FAIL (EXTENT)")
        return 1
    OVX, OVY, OVW, OVH, _ = ov[0]
    print(f"frame {W}x{H}   overview {OVW}x{OVH} at ({OVX},{OVY})")

    drift = (np.abs(a1 - a0).max(axis=2) > 10).sum()
    print(f"NODRIFT  a0 vs a1 changed {drift} px")
    if drift > W * H * 0.001:
        fails.append("NODRIFT")

    rows, live = {}, 0
    for name in TAGS:
        try:
            f = load(tag, name)
        except FileNotFoundError:
            continue
        live = max(live, int((np.abs(f - a0).max(axis=2) > 10).sum()))
        rows[name] = selected_row(f, a0)

    print(f"LIVE     largest t-frame diff vs a0 {live} px")
    if live < W * H * 0.01:
        fails.append("LIVE")

    for name in TAGS:
        r = rows.get(name)
        print(f"  {name}  " + ("none" if not r else f"row x={r[0]} y={r[1]} {r[2]}x{r[3]} ({r[4]}px)"))

    found = [r for r in rows.values() if r]
    if not found:
        print("WIDE     no selected row found on any frame")
        print("X49 GATE: FAIL (WIDE, HEADER, SECTIONS)")
        return 1

    # WIDE / HEADER graded on the widest row seen: a row still easing into place
    # is narrower than its resting box and would understate a passing build.
    x, y, w, h, _ = max(found, key=lambda r: r[2])
    span = 100.0 * w / OVW
    gapR = (OVX + OVW) - (x + w)
    gapL = x - OVX
    print(f"WIDE     row {w}px = {span:.1f}% of overview; right edge {gapR}px short, left inset {gapL}px")
    if span < 55.0:
        print("WIDE     the results are still the pill's width")
        fails.append("WIDE")
    if gapR > OVW * 0.04:
        print("WIDE     the rows do not reach the card's right edge")
        fails.append("WIDE")

    # 168 logical px of header column plus a card pad, at the overview's scale.
    # Bounded on BOTH sides: zero inset means no header column was reserved, and
    # a centred pill-width panel lands far past the upper bound.
    lo, hi = OVW * 0.04, OVW * 0.22
    print(f"HEADER   leading column {gapL}px, expected {lo:.0f}..{hi:.0f}px")
    if not (lo <= gapL <= hi):
        fails.append("HEADER")

    ys = [r[1] for name in TAGS if (r := rows.get(name))]
    steps = [b - a for a, b in zip(ys, ys[1:]) if b > a]
    print(f"SECTIONS selection tops {ys}")
    print(f"SECTIONS downward steps {steps}")
    if len(steps) < 2:
        print("SECTIONS not enough distinct selections to see a boundary")
        fails.append("SECTIONS")
    else:
        small, big = min(steps), max(steps)
        print(f"SECTIONS smallest {small}px, largest {big}px, ratio {big / max(1, small):.2f}")
        if big < small * 1.3:
            print("SECTIONS every step is the same -- one flat panel, not cards")
            fails.append("SECTIONS")

    fails = sorted(set(fails))
    print(("X49 GATE: FAIL (" + ", ".join(fails) + ")") if fails else "X49 GATE: PASS")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "post"))
