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
  PANEL    the selected result row (opaque accent) exists at all, and its TOP is
           below the half-way line OF THE OVERVIEW. This is DoD clause 23.
  STRIP    the region above the tiles -- the search row and the desktop strip --
           is quiet between a0 and b: the band does not push the strip down
           (DoD 18).
  TILES    the tile block gives its space back DOWNWARD: its top does not
           descend and its foot rises.

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
import sys
import pathlib
import numpy as np
from PIL import Image

OUT = pathlib.Path(__file__).resolve().parent / "x48"
S = 4                      # label on a 4x downsample; there is no scipy here
ACCENT = (0x50, 0x45, 0x36)  # general:col.active_border 77504536, alpha forced to 1


def load(tag, name):
    p = OUT / f"{tag}-{name}.png"
    return np.asarray(Image.open(p).convert("RGB")).astype(int)


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

    # PANEL. Accent-coloured AND changed: the wallpaper holds plenty of dark
    # warm brown and it is static, so intersecting with the change mask is what
    # separates the row from the backdrop it was tuned to sit against.
    near = np.ones(b.shape[:2], bool)
    for c in range(3):
        near &= np.abs(b[:, :, c] - ACCENT[c]) < 16
    rows = blobs(near & changed, limit=3)
    if not rows:
        print("PANEL    no accent row found")
        fails.append("PANEL")
    else:
        x, y, w, h, n = rows[0]
        print(f"PANEL    selected row at y={y} (x={x} {w}x{h}, {n}px)  -> {'BOTTOM' if y > MID else 'TOP'} half")
        if n < 3000:
            print("PANEL    blob too small to be a result row")
            fails.append("PANEL")
        elif y <= MID:
            fails.append("PANEL")

    # The biggest blob of fixture red is the main tile. The strip's own minis are
    # red too, and they legitimately re-lay-out under a query (F3-b), so the strip
    # is graded by how QUIET its region is, not by tracking a mini.
    ra, rb = blobs(red(a0), limit=1), blobs(red(b), limit=1)
    if not ra or not rb:
        print("TILES    no fixture tile found")
        fails.append("TILES")
        ra = rb = [(0, H, 0, 0, 0)]
    else:
        ta, tb = ra[0], rb[0]
        band = changed[OVY:min(ta[1], tb[1]), OVX:OVX + OVW]
        pct = 100.0 * band.sum() / max(1, band.size)
        print(f"STRIP    rows {OVY}..{min(ta[1], tb[1])} changed {band.sum()} of {band.size} = {pct:.2f}%")
        if pct > 5.0:
            print("STRIP    the chrome above the tiles MOVED -- the band is pushing it down")
            fails.append("STRIP")

    if ra[0][4]:
        ta, tb = ra[0], rb[0]
        print(f"TILES    top {ta[1]} -> {tb[1]}   foot {ta[1]+ta[3]} -> {tb[1]+tb[3]}")
        if tb[1] > ta[1] + 3:
            print("TILES    the tile block DESCENDED -- the band is pushing from the top")
            fails.append("TILES")
        if tb[1] + tb[3] > ta[1] + ta[3] - 8:
            print("TILES    the foot did not rise -- no space was given back downward")
            fails.append("TILES")

    print(("X48 GATE: FAIL (" + ", ".join(fails) + ")") if fails else "X48 GATE: PASS")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "post"))
