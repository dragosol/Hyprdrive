#!/usr/bin/env python3
"""X48 gate -- the results own the BOTTOM HALF. Runs on the HOST (guest has no numpy).

    x48_gate.py <tag>

Grades share/x48/<tag>-{00-a0,01-a1,20-b}.png.

Every check is bracketed so it can fail:
  NODRIFT  a0 vs a1 must be near-identical  -- a drifting output invalidates all
           the diffs below.
  LIVE     b must differ from a0            -- a STALLED output hands back the
           same frame forever, and every other check here would then compare a
           frame with itself and pass on zeros.
  ORDER    the selected result row (opaque accent) exists at all, and it sits
           ABOVE the tile block -- results between the search bar and the
           desktop strip, which is X60's placement.
  YIELDS   the band's space comes FROM THE TILE GRID: the tile block is shorter
           under a query than at rest.
  ONSCREEN nothing is shoved off: the tile block's foot stays clear of the dock,
           which is X48's actual constraint and the one X60 kept.

THIS GATE USED TO ASSERT THE OPPOSITE, AND THE SPEC MOVED UNDER IT. X48 and
DoD 23 put the results in the BOTTOM half and this file graded exactly that:
PANEL wanted the selected row below the overview's midline, STRIP wanted the
chrome above the tiles to be quiet, TILES wanted the block's foot to RISE.
Then the user reported (2026-08-05, spec 13.12 X60) "the search results are all
the way at the bottom and they should be between the search bar and the desktop
bar", and X60 says in terms: "This SUPERSEDES X48's placement". The band became
top chrome in 2bc0633, measured there as the selected cell moving y=753 -> y=164
-- which is the same number this gate has been reporting as a defect ever since
(y=160 at 2560x1600). Three failures, one superseded clause.

X48's real complaint survives and is what ORDER/YIELDS/ONSCREEN now grade: the
results must not shove the overview down and off the screen -- the band takes
its space from the tile grid, never from the strip going off the top.

Two traps this gate walked into first, both recorded because each one made a
working build read as broken:

  * The half-way line is the OVERVIEW's, not the screen's. The overview renders
    into a scaled card inset from the monitor (here rows 100..984 of a 1080-row
    frame), so its own bottom half starts ABOVE the screen's midline and a
    correctly placed panel scores as "top half" against y=540.
  * The strip region must stop at the HIGHER of the two tile tops. Measured down
    to a0's tile top it swallows the rows the tiles rose THROUGH, and reads
    16.27% changed where the strip itself moved not at all (1.79%).

Blobs, never bounding boxes of a whole colour mask: the fixture red is in the
main tile AND in the strip mini, so a bbox over all of it spans nearly the whole
screen and cannot move whatever the compositor does.
"""
import json
import sys
import pathlib
import numpy as np
from PIL import Image

OUT = pathlib.Path(__file__).resolve().parent / "x48"
S = 4                      # label on a 4x downsample; there is no scipy here


def load(tag, name):
    p = OUT / f"{tag}-{name}.png"
    return np.asarray(Image.open(p).convert("RGB")).astype(int)


def accent(out):
    """The colour the plugin actually draws a SELECTION with, read back from the
    frame's own session -- never spelled out here.

    Two separate ways the literal (0x50, 0x45, 0x36) had gone stale:

      * it is `general:col.active_border` as matugen derived it from ONE
        wallpaper, and matugen re-derives the palette from whatever picture is
        up. On wp17 -- the greyscale image pinwall.sh pins precisely so colour
        locators are safe -- col.active_border is 77424753;
      * and since X56 the selection is not drawn with col.active_border at all.
        Config.cpp's highlightColor() prefers `plugin:hyprdrive:col_highlight`
        (matugen's `primary`, currently ffadc6ff) and only falls back to
        col.active_border when that key is UNSET, which it signals with alpha 0.

    A locator looking for the old brown found nothing on any frame, and "no
    selection on any frame" reads exactly like a build that stopped drawing
    selections. So this mirrors highlightColor() over the two files the x48
    fixture dumps beside the frames.
    """
    for name, need_alpha in (("highlight.json", True), ("accent.json", False)):
        p = out / name
        if not p.exists():
            continue
        v = int(json.loads(p.read_text())["gradient"].split()[0], 16)   # AARRGGBB
        if need_alpha and (v >> 24) & 0xFF == 0:
            continue        # alpha 0 means UNSET -- fall through, as the plugin does
        return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    raise SystemExit("no highlight.json/accent.json next to the frames -- rerun the "
                     "x48 fixture, which is what writes them")
    g = json.loads(p.read_text())["gradient"].split()[0]
    v = int(g, 16)                       # AARRGGBB; alpha is forced to 1 on the selection
    return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)


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


def red(im):
    return (im[:, :, 0] > 150) & (im[:, :, 1] < 90) & (im[:, :, 2] < 90)


def main(tag):
    a0, a1, b = load(tag, "00-a0"), load(tag, "01-a1"), load(tag, "20-b")
    H = a0.shape[0]
    ACCENT = accent(OUT)
    print(f"accent   #{ACCENT[0]:02x}{ACCENT[1]:02x}{ACCENT[2]:02x}  (read back from accent.json)")
    fails = []

    # The overview's own extent: the largest non-black blob, i.e. the wallpaper
    # card the whole overview is drawn into.
    ov = blobs(a0.mean(axis=2) > 22, limit=1)
    if not ov:
        print("EXTENT   no overview card found -- nothing below can be believed")
        print("X48 GATE: FAIL (EXTENT)")
        return 1
    OVX, OVY, OVW, OVH, _ = ov[0]
    MID = OVY + OVH // 2

    changed_ctrl = (np.abs(a1 - a0).max(axis=2) > 10)
    changed = (np.abs(b - a0).max(axis=2) > 10)
    print(f"frame {a0.shape[1]}x{H}  overview {OVW}x{OVH} at ({OVX},{OVY})  its midline y={MID}")
    print(f"NODRIFT  a0 vs a1 changed {changed_ctrl.sum()} px")
    print(f"LIVE     a0 vs b  changed {changed.sum()} px")
    if changed_ctrl.sum() > H * a0.shape[1] * 0.001:
        fails.append("NODRIFT")
    if changed.sum() < H * a0.shape[1] * 0.01:
        fails.append("LIVE")

    # The tile block: the biggest blob of fixture red. Needed by ORDER as well
    # as by the two below, so it is measured first.
    ra, rb = blobs(red(a0), limit=1), blobs(red(b), limit=1)
    if not ra or not rb:
        print("TILES    no fixture tile found -- nothing below can be believed")
        print("X48 GATE: FAIL (TILES)")
        return 1
    ta, tb = ra[0], rb[0]
    A_TOP, A_FOOT = ta[1], ta[1] + ta[3]
    B_TOP, B_FOOT = tb[1], tb[1] + tb[3]
    print(f"TILES    top {A_TOP} -> {B_TOP}   foot {A_FOOT} -> {B_FOOT}   height {ta[3]} -> {tb[3]}")

    # ORDER. Accent-coloured AND changed: the wallpaper holds plenty of dark
    # warm brown and it is static, so intersecting with the change mask is what
    # separates the row from the backdrop it was tuned to sit against.
    near = np.ones(b.shape[:2], bool)
    for c in range(3):
        near &= np.abs(b[:, :, c] - ACCENT[c]) < 16
    rows = blobs(near & changed, limit=3)
    if not rows:
        print("ORDER    no accent row found")
        fails.append("ORDER")
    else:
        x, y, w, h, n = rows[0]
        print(f"ORDER    selected row at y={y}..{y+h} (x={x} {w}x{h}, {n}px), tile block top {B_TOP}")
        if n < 3000:
            print("ORDER    blob too small to be a result row")
            fails.append("ORDER")
        elif y + h > B_TOP:
            print("ORDER    the results are NOT above the tile block")
            fails.append("ORDER")

    # YIELDS. X60: "the band takes its space from the tile grid". The block is
    # shorter under a query than at rest, and by more than the locator's own
    # jitter -- NODRIFT above bounds that at tens of pixels over the whole frame.
    if tb[3] >= ta[3] - 8:
        print(f"YIELDS   the tile block did not give the band any height ({ta[3]} -> {tb[3]})")
        fails.append("YIELDS")

    # ONSCREEN. X48's surviving constraint, and the reason X60 quotes it: the
    # results must not shove the overview down and off the screen. The dock is
    # the thing the tiles would be shoved under, and it is located the way the
    # standing doctrine locates a dock -- the biggest lit blob ANCHORED to the
    # bottom edge of the frame, not a hardcoded y.
    docks = [d for d in blobs(a0.mean(axis=2) > 22, limit=6) if d[1] > H * 0.85]
    if not docks:
        print("ONSCREEN no dock found at the bottom edge -- cannot bound the tiles")
        fails.append("ONSCREEN")
    else:
        DOCKTOP = docks[0][1]
        print(f"ONSCREEN tile foot {B_FOOT} vs dock top {DOCKTOP}")
        if B_FOOT > DOCKTOP:
            print("ONSCREEN the tile block was pushed UNDER the dock")
            fails.append("ONSCREEN")

    print(("X48 GATE: FAIL (" + ", ".join(fails) + ")") if fails else "X48 GATE: PASS")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "post"))
