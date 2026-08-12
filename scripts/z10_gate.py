#!/usr/bin/env python3
"""z10_theme_adopt grader: did a wallpaper swap actually repaint the accents?

Two surfaces, measured two different ways, because they fail two different ways.

DOCK -- an absolute measurement against a controlled backdrop. The pill is
translucent, so anything behind it changes its pixels; the rig therefore parks
an OPAQUE kitty across the whole dock band, and the pill's backdrop is then a
constant that the wallpaper cannot move. What is left that can change the pill
is the pill's own hue and alpha, which is exactly the thing under test. Three
controls ride along: a same-palette frame pair for the noise floor, the fixture
OUTSIDE the pill for "the backdrop really did hold still", and the direction of
the colour move against the value the palette predicts -- a pill that changed by
the right amount in the wrong direction is not a pill that adopted the theme.

OVERVIEW -- a colour-membership measurement, because the strip selection ring is
two pixels wide and sits on a wallpaper that is changing underneath it at the
same time. Counting "pixels within 28 of the NEW accent" only means something if
the new wallpaper does not itself contain that colour, so the accents are chosen
for that and the claim is CHECKED, per frame, in a strip of pure wallpaper down
each edge of the frame. This is the z3 trap wired to an alarm: z3 takes the
largest yellow blob over a whole desktop that has a photograph on it, and on the
golden-hillside wallpaper it finds the hillside. Measured 2026-08-12, the two
accents this gate swaps between match 0.000% of all 22 of the guest's
wallpapers at tolerance 28 -- but the gate does not trust the measurement, it
re-takes it every run.

usage: z10_gate.py MANIFEST.json
"""
import json
import pathlib
import sys

import numpy as np
from PIL import Image

TOL = 28          # RGB distance that counts as "this pixel is the accent"
DOWN = 4          # blob labelling downsample [blob.py:11]


def rgb(s):
    s = s.strip().lstrip("#")
    return np.array([int(s[i:i + 2], 16) for i in (0, 2, 4)])


def load(p):
    return np.asarray(Image.open(p).convert("RGB")).astype(int)


def dilate(m, r=3):
    """Standing pixel doctrine: dilate before labelling. The strip selection
    ring is two pixels wide, and a two-pixel ring sampled every fourth pixel is
    not a connected component, it is a dotted line -- the labeller would return
    the biggest ARC of the ring and the ROI would be a quarter of it."""
    out = m.copy()
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            out |= np.roll(np.roll(m, dy, 0), dx, 1)
    return out


def largest_blob(mask, s=DOWN):
    """(y0, y1, x0, x1, mask) of the biggest connected component. No scipy in
    this guest, so it is blob.py's downsample-and-flood, generalised."""
    small = mask[::s, ::s]
    if not small.any():
        return None
    seen = np.zeros_like(small)
    best, best_n = None, 0
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
        if len(comp) > best_n:
            best, best_n = comp, len(comp)
    ys, xs = np.array(best).T
    y0, y1, x0, x1 = ys.min() * s, (ys.max() + 1) * s, xs.min() * s, (xs.max() + 1) * s
    out = np.zeros_like(mask)
    out[y0:y1, x0:x1] = mask[y0:y1, x0:x1]
    return y0, y1, x0, x1, out


class Report:
    def __init__(self):
        self.fail = 0

    def say(self, *a):
        print(*a)

    def want(self, ok, msg):
        if not ok:
            print("FAIL " + msg)
            self.fail = 1
        return ok


def pair_live(R, tag, a, b):
    """Identical frames prove nothing; a frozen output would report 'nothing
    changed' forever [rig.sh pipeline_live_or_die]."""
    return R.want(not np.array_equal(a, b), "%s: the two control frames are byte-identical "
                                            "-- the capture is frozen and every number below is void" % tag)


# ------------------------------------------------------------------- dock --
def dock_check(R, m, chk):
    out = pathlib.Path(m["out"])
    f0, f1 = load(out / ("dock-%s-0.png" % chk["from"])), load(out / ("dock-%s-1.png" % chk["from"]))
    g0, g1 = load(out / ("dock-%s-0.png" % chk["to"])), load(out / ("dock-%s-1.png" % chk["to"]))
    name = chk["name"]
    pair_live(R, name + " before", f0, f1)
    pair_live(R, name + " after", g0, g1)

    fix = rgb(m["fixture"])
    y0, y1 = m["dock_band"]
    band = np.zeros(f0.shape[:2], bool)
    band[y0:y1, :] = True
    # The pill is what is NOT the fixture inside the dock band.
    off = np.sqrt(((f0 - fix) ** 2).sum(2)) > 8
    blob = largest_blob(off & band)
    if not R.want(blob is not None, "%s: no dock pill found over the fixture -- is the dock hidden?" % name):
        return
    py0, py1, px0, px1, pill = blob
    area = int(pill.sum())
    R.say("%s: pill blob %dx%d at (%d,%d), %d px" % (name, px1 - px0, py1 - py0, px0, py0, area))
    if not R.want(area > 5000, "%s: the pill blob is only %d px -- that is not a dock" % (name, area)):
        return

    # The backdrop control: fixture pixels in the band, well clear of the pill.
    ctrl = band & ~off
    ctrl[:, max(0, px0 - 40):px1 + 40] = False

    def mad(a, b, mask):
        return float(np.abs(a - b)[mask].mean()) if mask.any() else float("nan")

    noise = max(mad(f0, f1, pill), mad(g0, g1, pill))
    signal = mad(f0, g0, pill)
    backdrop = mad(f0, g0, ctrl)
    R.say("%s: pill delta %.2f  (noise floor %.2f, backdrop control %.2f over %d px)"
          % (name, signal, noise, backdrop, int(ctrl.sum())))

    R.want(backdrop <= 1.5, "%s: the backdrop moved by %.2f -- the fixture did not hold the pill's "
                            "background still, so the pill delta is not attributable" % (name, backdrop))

    if chk["expect"] == "change":
        # Direction. The pill is hue over a fixed backdrop at alpha, so the mean
        # move should be alpha * (new hue - old hue).
        obs = (g0 - f0)[pill].reshape(-1, 3).mean(0)
        pred = m["alpha"] * (rgb(m["steps"][chk["to"]]["pill"]) - rgb(m["steps"][chk["from"]]["pill"]))
        cos = float(obs @ pred / ((np.linalg.norm(obs) * np.linalg.norm(pred)) or 1))
        R.say("%s: move %s, palette predicts %s, cos %.3f"
              % (name, np.round(obs, 1).tolist(), np.round(pred, 1).tolist(), cos))
        R.want(signal >= 3.0, "%s: the pill moved %.2f, wanted >= 3.0 -- the dock did not adopt the palette"
               % (name, signal))
        R.want(signal >= 4 * noise, "%s: the pill move %.2f is not 4x its own noise floor %.2f"
               % (name, signal, noise))
        R.want(cos >= 0.7, "%s: the pill moved in the wrong direction for this palette (cos %.3f)" % (name, cos))
    else:
        R.want(signal <= max(1.0, 2 * noise),
               "%s: the pill moved %.2f (noise %.2f) -- a PINNED surface adopted the palette anyway"
               % (name, signal, noise))


# --------------------------------------------------------------- overview --
def ring_check(R, m, chk):
    out = pathlib.Path(m["out"])
    f0, f1 = load(out / ("ov-%s-0.png" % chk["from"])), load(out / ("ov-%s-1.png" % chk["from"]))
    g0, g1 = load(out / ("ov-%s-0.png" % chk["to"])), load(out / ("ov-%s-1.png" % chk["to"]))
    name = chk["name"]
    pair_live(R, name + " before", f0, f1)
    pair_live(R, name + " after", g0, g1)

    old, new = rgb(m["steps"][chk["from"]]["accent"]), rgb(m["steps"][chk["to"]]["accent"])

    def hits(fr, c):
        return np.sqrt(((fr - c) ** 2).sum(2)) < TOL

    # LOCATE the ring before counting anything, from the largest connected blob
    # of the OLD accent -- never a count over a band. A band big enough to hold
    # the strip on this desktop also holds the corner of the quickshell clock
    # widget, which is accent-tinted too and contributed ~500 px of "the
    # overview repainted" in the first cut of this gate. The ring is one
    # connected outline and it is the biggest thing of its colour; the widget is
    # somewhere else and does not join it.
    blob = largest_blob(dilate(hits(f0, old)), s=2)
    if not R.want(blob is not None, "%s: no ring of the old accent anywhere -- nothing to repaint" % name):
        return
    y0, y1, x0, x1, _ = blob
    P = 12
    y0, y1 = max(0, y0 - P), min(f0.shape[0], y1 + P)
    x0, x1 = max(0, x0 - P), min(f0.shape[1], x1 + P)
    roi = np.zeros(f0.shape[:2], bool)
    roi[y0:y1, x0:x1] = True
    sy0, sy1 = m["strip_band"]
    R.say("%s: ring located at (%d,%d) %dx%d" % (name, x0, y0, x1 - x0, y1 - y0))
    R.want(sy0 <= (y0 + y1) // 2 <= sy1,
           "%s: the biggest blob of the accent is at y=%d, outside the strip band %d..%d -- that is not the ring"
           % (name, (y0 + y1) // 2, sy0, sy1))

    b_old, b_new = int((hits(f0, old) & roi).sum()), int((hits(f0, new) & roi).sum())
    a_old, a_new = int((hits(g0, old) & roi).sum()), int((hits(g0, new) & roi).sum())
    R.say("%s: accent %s -> %s | in ring: before old=%d new=%d | after old=%d new=%d"
          % (name, m["steps"][chk["from"]]["accent"], m["steps"][chk["to"]]["accent"], b_old, b_new, a_old, a_new))

    # THE control that makes the counts mean anything: the same masks over pure
    # wallpaper down both edges of each frame. If the wallpaper supplies the
    # accent, this is where it shows up first (z3 is red on some wallpapers for
    # exactly this reason, and its mask is much broader than 28).
    edge = m["edge_px"]
    k = np.zeros(f0.shape[:2], bool); k[:, :edge] = True; k[:, -edge:] = True
    w_old, w_new = int((hits(f0, old) & k).sum()), int((hits(g0, new) & k).sum())
    R.say("%s: wallpaper control (%d px of edge): before-old %d, after-new %d" % (name, edge, w_old, w_new))
    R.want(w_old < 200 and w_new < 200,
           "%s: the accent masks are finding the WALLPAPER (%d/%d px on pure-wallpaper edges) -- "
           "these counts cannot separate the ring from the photograph" % (name, w_old, w_new))

    R.want(b_old >= 300, "%s: only %d px of the OLD accent in the ring -- there is no ring to repaint"
           % (name, b_old))
    R.want(b_new <= 0.2 * b_old, "%s: %d px of the NEW accent were in the ring BEFORE the swap -- the two "
           "accents are not separable here" % (name, b_new))
    if chk["expect"] == "change":
        R.want(a_new >= 0.5 * b_old, "%s: the new accent covers %d px of the ring, wanted >= %d -- the overview "
               "did not adopt the palette" % (name, a_new, int(0.5 * b_old)))
        R.want(a_old <= 0.2 * b_old, "%s: %d px of the OLD accent survived the swap (was %d)" % (name, a_old, b_old))
    else:
        R.want(a_old >= 0.8 * b_old, "%s: only %d of %d px of the pinned accent survived" % (name, a_old, b_old))


def main(argv):
    m = json.loads(pathlib.Path(argv[1]).read_text())
    R = Report()
    for chk in m["checks"]:
        print("--- %s (%s -> %s, expect %s)" % (chk["name"], chk["from"], chk["to"], chk["expect"]))
        (dock_check if chk["kind"] == "dock" else ring_check)(R, m, chk)
        print()
    print("Z10 " + ("PASS -- a wallpaper swap repaints the dock and the overview, and a pinned surface masks it"
                    if not R.fail else "FAIL"))
    return R.fail


if __name__ == "__main__":
    sys.exit(main(sys.argv))
