#!/usr/bin/env python3
"""X47 gate. Runs on the HOST against /home/dragos/hyprvm/share/x47 (guest has
no numpy). Grades the four claims x47_rig.sh captures for.

WHY IT IS SHAPED LIKE THIS. The guest wallpaper drifts and the panel is frosted,
so "this frame differs from that one" is not evidence of anything on its own --
a previous fire's brightness detector reported the dock's close button present
with the pointer parked far away, because it was counting wallpaper cloud. So:

  * TWO controls before the hover and ONE after. Anything the gate calls signal
    must differ from BOTH pre-controls, and the noise mask built from all three
    control pairs is dilated before it is subtracted.
  * The score is the LARGEST CONNECTED BLOB, not the bounding box of every
    changed pixel: scattered wallpaper noise spans the whole band and pins a
    bbox at full width in every frame, which is a check that cannot fail.
  * The blob has to land where the panel is PREDICTED to be, from Dock.cpp's
    constants. A blob of the right size in the wrong place is a fail.
  * c2 is graded too. If the panel never dismissed, c2 is contaminated, the mask
    swallows the panel and every other check goes green for the wrong reason --
    so "the panel left" is an assertion, not an assumption.

usage: x47_gate.py <tag>
"""
import sys
import pathlib
import numpy as np
from PIL import Image

DIR = pathlib.Path("/home/dragos/hyprvm/share/x47")
TAG = sys.argv[1] if len(sys.argv) > 1 else "run"

THRESH = 18      # per-channel, 0..255
DILATE = 3       # noise mask growth, in downsampled cells
S = 2            # blob labelling downsample


def load(name):
    p = DIR / ("%s-%s.png" % (TAG, name))
    if not p.exists():
        sys.exit("MISSING FRAME: %s" % p)
    return np.asarray(Image.open(p).convert("RGB")).astype(np.int16)


def differs(a, b):
    return np.abs(a - b).max(axis=2) > THRESH


def dilate(mask, r):
    out = mask.copy()
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            out |= np.roll(np.roll(mask, dy, axis=0), dx, axis=1)
    return out


def largest_blob(mask):
    """(area_full_res, x, y, w, h) of the biggest 4-connected component."""
    small = mask[::S, ::S]
    if not small.any():
        return 0, None
    seen = np.zeros_like(small)
    best = []
    ys, xs = np.where(small)
    for sy, sx in zip(ys, xs):
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
        if len(comp) > len(best):
            best = comp
    if not best:
        return 0, None
    cy = [c[0] for c in best]
    cx = [c[1] for c in best]
    box = (min(cx) * S, min(cy) * S, (max(cx) - min(cx) + 1) * S, (max(cy) - min(cy) + 1) * S)
    return len(best) * S * S, box


c0, c1, c2 = load("c0"), load("c1"), load("c2")
h0, h1, t0, g0 = load("h0"), load("h1"), load("t0"), load("g0")

# The band's own origin, so a predicted panel rect in screen coords can be
# compared with a blob in band coords.
px, py, pw, ph = [int(v) for v in (DIR / ("%s-panel.txt" % TAG)).read_text().split()]
BAND_TOP = py - 24

NOISE = dilate(differs(c0, c1) | differs(c0, c2) | differs(c1, c2), DILATE)
print("noise mask: %d px of %d (%.2f%%)" % (NOISE.sum(), NOISE.size, 100.0 * NOISE.sum() / NOISE.size))


def signal(frame):
    return differs(c0, frame) & differs(c1, frame) & ~NOISE


results = []


def check(name, ok, detail):
    results.append((name, ok, detail))
    print("%-9s %s  %s" % (name, "PASS" if ok else "FAIL", detail))


area_h0, box_h0 = largest_blob(signal(h0))
area_g0, box_g0 = largest_blob(signal(g0))
area_t0, box_t0 = largest_blob(signal(t0))
area_c2, _ = largest_blob(differs(c0, c2) & differs(c1, c2) & ~dilate(differs(c0, c1), DILATE))

# --- FRESH. Graded before anything else, because a dead capture pipeline makes
# --- every "the panel is gone" check pass for the wrong reason. The first run
# --- of this rig scored 0 changed pixels EVERYWHERE, including between two
# --- frames of a counter ticking every 80ms: Virtual-1 draws ~1fps with no
# --- viewer attached and grim was handing back one stale frame seven times.
p0, p1 = load("p0"), load("p1")
live_px = differs(p0, p1).sum()
check("FRESH", live_px > 0,
      "%d px changed between two full-screen grabs of a counter ticking every 80ms" % live_px)

# --- PANEL. FRESH proves the FULL-SCREEN grim path is live and says NOTHING
# --- about `grim -g "$BAND"`, which is where every check below gets its pixels.
# --- Run `c` (2026-08-03 20:31Z) had all seven band frames byte-identical while
# --- FRESH passed on p0/p1, and both ratio checks below are true of nothing:
# --- LEFT reads 0 < 2000 and GRACE reads 0 >= 0, so a blank set scored 2 green.
check("PANEL", area_h0 > 20000,
      "%d px of panel in the BAND path; below this nothing else is measurable" % area_h0)

# --- the panel LEFT. Graded first: everything below leans on c2 being clean. --
check("LEFT", area_h0 > 20000 and area_c2 < max(2000, 0.05 * area_h0),
      "post-control blob %d px, vs %d px while hovered" % (area_c2, area_h0))

# --- RISES ------------------------------------------------------------------
ok = area_h0 > 20000 and box_h0 is not None
where = ""
if box_h0 is not None:
    bx, by, bw, bh = box_h0
    # Predicted, in band coords. Width is the WIDEST icon's panel, so the blob
    # may be narrower; position and height are the parts that must match.
    exp_y = py - BAND_TOP
    dy = abs(by - exp_y)
    ok = ok and dy <= 40 and bh >= 0.6 * ph and bw >= 200
    where = "blob %dx%d at (%d,%d), predicted y=%d h=%d -> dy=%d" % (bw, bh, bx, by, exp_y, ph, dy)
check("RISES", ok, "%d px; %s" % (area_h0, where))

# --- LIVE: the contents change on their own -------------------------------
# Restricted to the blob the panel actually occupies, and compared against the
# SAME region across the two controls -- which is what separates "the preview is
# live" from "something on screen moved".
region = np.zeros(NOISE.shape, dtype=bool)
if box_h0 is not None:
    bx, by, bw, bh = box_h0
    region[by:by + bh, bx:bx + bw] = True
live = (differs(h0, h1) & region).sum()
ctrl = (differs(c0, c1) & region).sum()
check("LIVE", live > 400 and live > 8 * max(ctrl, 1),
      "%d px changed between two hovered frames, vs %d px between two idle ones" % (live, ctrl))

# --- FOLLOWS ---------------------------------------------------------------
ok, detail = False, "no blob on the second icon"
if box_t0 is not None and box_h0 is not None:
    ch = box_h0[0] + box_h0[2] / 2.0
    ct = box_t0[0] + box_t0[2] / 2.0
    ok = area_t0 > 20000 and abs(ct - ch) >= 40
    detail = "panel centre %d -> %d (moved %d px), %d px" % (ch, ct, abs(ct - ch), area_t0)
check("FOLLOWS", ok, detail)

# --- GRACE -----------------------------------------------------------------
# Against t0, NOT h0: the pointer leaves from the SECOND icon, so the plate that
# has to survive the grace period is that icon's, and its window count -- and so
# its area -- is its own.
check("GRACE", area_t0 > 20000 and area_g0 >= 0.5 * area_t0,
      "%d px still up 120ms after the pointer left the second icon, vs %d px while it was hovered" % (area_g0, area_t0))

bad = [n for n, ok, _ in results if not ok]
print()
print("X47 GATE: %s" % ("PASS" if not bad else "FAIL (%s)" % ", ".join(bad)))
sys.exit(1 if bad else 0)
