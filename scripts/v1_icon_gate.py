"""V1 (user, 2026-08-17): the tile icon FADES AND GROWS with the overview open.

    "Start of animation - size 0. End of overview animation - whatever size the
     icons in the bottom middle of the windows end up at. So both fade and grow."

WHAT IS MEASURED, and why it is measured INSIDE the tile.

The icon straddles the tile's bottom edge, so its top half sits on the fixture's
own uniform magenta and its bottom half sits on the card. Only the top half is
graded: over a solid fixture colour "not the fixture colour" is an unambiguous
icon mask, while below the edge the reference is a wallpaper and any threshold
there grades the picture. The reference magenta is re-read from a control strip
in the SAME rows on every frame, so the tile's own fade-in, dimming or blending
cannot be mistaken for the icon appearing -- and that strip doubles as the
control that says the mask sees NOTHING where there is no icon.

FULL RESOLUTION, DELIBERATELY. blob.largest_of labels on a 4x downsample, which
is right for a 700 px tile and useless for a 72 px icon: it quantises the width
to 4 px and the area to 16, and it puts the anchor row within 4 px, which alone
moves the measured area by a tenth. So the tile is FOUND with largest_of and
then MEASURED at full resolution -- its bottom row and centre read off columns
that the icon does not cover, and the icon's own extent counted pixel by pixel.
Measured effect: the plateau stops wobbling +-4 px / +-9% and holds to 1 px.

The tile MOVES and SHRINKS through the open, so the anchor is recomputed per
frame: TileChrome centres the icon box on (tile centre x, tile bottom y), and
that is the point everything here is measured around.

WHY WIDTH AND NOT ONLY AREA. The old build fades a FULL-SIZE icon in, so its
first measurable frame is a full-width icon at low alpha; this build's first
measurable frame is a few pixels across. Area conflates the two -- a faint full
icon and a solid small one can score alike once a threshold is involved -- while
the WIDTH of the mask separates them, and the fail-on-old arm is exactly that.
Area is still the series graded for monotonicity: it is what the spec names, and
it is the more sensitive of the two.

THE TILE IS ALSO THE CLOCK. The tile's drawn box is a function of the same open
progress the icon now rides, so the frame the tile stops moving IS the frame the
overview settles -- no second instrument, and the grid reflow (300 ms) is long
over inside a 2 s open. "Never finishes after the overview" is graded against
that frame directly.

Curve shape uses the house reading [archive: grade eased curves by span, and
x64_motion.py]: where the series has done half its total work, as a fraction of
its own duration. Below 0.45 decelerates.
"""
import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
from PIL import Image

from blob import largest_of

# The strip band draws a mini of the same fixture; everything above this row is
# dropped so "the tile" cannot be a 76x48 cell.
STRIP_FLOOR = 450
# Smaller than this is a rounded corner or a sliver of chrome, not the tile.
MIN_TILE_PX = 40000

# The icon ROI, in pixels around the tile's bottom-middle anchor. ICON_MAX is 72
# and the fixture is sized so the clamp holds all the way through the open, so
# 90 is wider than anything that can be drawn and still far from the tile's
# rounded corners.
ROI = 90
# Rows [anchor_y - ROI, anchor_y - EDGE_GUARD): the tile's own last two rows are
# antialiased against the card across its whole width and read as a 180 px
# "icon" if they are included. Two rows, and no more -- a bigger guard eats the
# only rows a nearly-zero-sized icon occupies, which is the measurement this
# gate exists for.
EDGE_GUARD = 2
# The control strip: same rows, far enough left of the icon to be clear of it
# and still inside the tile at its smallest.
REF_NEAR = 150
REF_FAR = 260
# A pixel is "not the fixture colour" past this per-channel distance. Above the
# codec's colour noise on a flat field (measured: the control strip scores 0-1
# deviating pixels per frame) and low enough that an icon at a fifth of its
# opacity still reads.
DEV = 22
# A column counts toward the icon's width once two of its pixels deviate: one
# stray pixel is noise, and requiring a run makes the width the icon's own
# rather than the noise floor's.
COL_MIN = 2


def _longest_run(flags):
    best = run = 0
    for f in flags:
        run = run + 1 if f else 0
        best = max(best, run)
    return best


def tile_and_icon(png):
    """-> (tile_width, icon_width, icon_area, control_px) for one frame."""
    im = np.asarray(Image.open(png).convert("RGB")).astype(int)
    r, g, b = im[:, :, 0], im[:, :, 1], im[:, :, 2]
    mask = (r > 110) & (b > 110) & (g < 90) & (r - g > 60) & (b - g > 60)
    mask[:STRIP_FLOOR, :] = False
    coarse = largest_of(mask)
    if not coarse or coarse[4] < MIN_TILE_PX:
        return 0, 0, 0, 0

    # Full-resolution anchor. A row well inside the tile gives its left and right
    # edges (and so its centre and its true width); a column well left of centre
    # gives its bottom row without the icon punching a hole in the answer.
    probe_row = min(im.shape[0] - 1, coarse[1] + coarse[3] - 12)
    cols = np.where(mask[probe_row])[0]
    if cols.size < 40:
        return 0, 0, 0, 0
    left, right = int(cols.min()), int(cols.max())
    ax = (left + right) // 2
    tw = right - left + 1

    probe_col = max(0, ax - (REF_NEAR + REF_FAR) // 2)
    rows = np.where(mask[:, probe_col])[0]
    if rows.size < 10:
        return tw, 0, 0, 0
    ay = int(rows.max())

    y1, y0 = ay - EDGE_GUARD, ay - ROI
    if y0 < 0 or y1 - y0 < 10:
        return tw, 0, 0, 0

    ref = im[y0:y1, max(0, ax - REF_FAR):max(1, ax - REF_NEAR)]
    if ref.size == 0:
        return tw, 0, 0, 0
    base = np.median(ref.reshape(-1, 3), axis=0)

    control = int((np.abs(ref - base).max(axis=2) > DEV).sum())

    roi = im[y0:y1, max(0, ax - ROI):ax + ROI]
    dev = np.abs(roi - base).max(axis=2) > DEV
    width = _longest_run(dev.sum(axis=0) >= COL_MIN)
    return tw, width, int(dev.sum()), control


def series(frames):
    rows = []
    for p in sorted(glob.glob(os.path.join(frames, "*.png"))):
        rows.append((os.path.basename(p),) + tile_and_icon(p))
    return rows


def smooth(vals, k=5):
    """Median filter. The per-frame codec noise on a 72 px blob is worth several
    percent of its area; the trend under it is not noisy at all."""
    a = np.asarray(vals, dtype=float)
    out = a.copy()
    for i in range(len(a)):
        lo, hi = max(0, i - k // 2), min(len(a), i + k // 2 + 1)
        out[i] = np.median(a[lo:hi])
    return out


def half_work(vals):
    """Fraction of the span at which half the total change has happened."""
    steps = np.abs(np.diff(np.asarray(vals, dtype=float)))
    if steps.sum() <= 0:
        return 1.0
    cum = np.cumsum(steps) / steps.sum()
    return float(np.searchsorted(cum, 0.5) + 1) / len(steps)


def grade_open(rows, dump=False):
    fail = 0
    drawn = [i for i, r in enumerate(rows) if r[1] > 0]
    if len(drawn) < 20:
        print("FAIL the fixture tile is in only %d frames -- rig fault, nothing to grade" % len(drawn))
        return 1

    tilew = [rows[i][1] for i in drawn]
    widths = [rows[i][2] for i in drawn]
    areas = [rows[i][3] for i in drawn]
    control = [rows[i][4] for i in drawn]

    if dump:
        for k, i in enumerate(drawn):
            print("      %4d %-12s tile %4d  icon w %3d  area %5d  control %d"
                  % (k, rows[i][0], tilew[k], widths[k], areas[k], control[k]))

    # THE CONTROL. The same test, the same rows, on tile that has no icon on it.
    # If this is not ~zero the mask is grading the fixture, not the icon.
    if max(control) > 40:
        print("FAIL the control strip scores up to %d deviating pixels -- the icon mask "
              "is picking up the tile itself, so nothing below means anything" % max(control))
        return 1

    # THE OVERVIEW'S SETTLE, read off the tile: the last frame whose drawn width
    # differs from the final one. The tile's box is a function of the same open
    # progress, so this is the open's own end and not a second clock.
    final_tw = int(np.median(tilew[-5:]))
    settle = 0
    for k in range(len(tilew)):
        if abs(tilew[k] - final_tw) > 2:
            settle = k
    moved = [k for k in range(len(tilew)) if abs(tilew[k] - tilew[0]) > 4]
    if not moved or settle <= moved[0] + 5:
        print("FAIL the film never caught the open MOVING and then STOPPED "
              "(first move %s, settle %d of %d) -- no controls on either side"
              % (moved[0] if moved else None, settle, len(tilew)))
        return 1
    if settle > len(tilew) - 6:
        print("FAIL the film ended while the overview was still opening (settle %d of %d)"
              % (settle, len(tilew)))
        fail = 1
    if len(set(tilew[moved[0]:settle + 1])) < 8:
        print("FAIL only %d distinct tile widths across the open -- the capture is "
              "repeating frames, not filming motion" % len(set(tilew[moved[0]:settle + 1])))
        fail = 1

    rest_w = int(np.median([w for w in widths[settle:] if w > 0] or [0]))
    rest_a = float(np.median([a for a in areas[settle:] if a > 0] or [0]))
    if rest_w < 30:
        print("FAIL no icon at rest (%d px) -- the gate is not photographing an icon" % rest_w)
        return 1

    seen = [k for k in range(len(widths)) if widths[k] > 0]
    first, first_w = seen[0], widths[seen[0]]

    sm = smooth(areas)
    ramp = [k for k in seen if 0.2 * rest_w <= widths[k] <= 0.8 * rest_w]
    reach = next((k for k in range(len(widths)) if widths[k] >= rest_w - 2), None)
    peak_w, peak_a = max(widths), float(sm.max())
    grow = widths[first:(reach if reach is not None else settle) + 1]
    half = half_work(grow) if len(grow) > 2 else 1.0

    print("    frames %d  tile drawn %d  first move %d  overview settle %d  control max %d px"
          % (len(rows), len(drawn), moved[0], settle, max(control)))
    print("    icon width: resting %d  first seen at frame %d = %d px (%.2f of resting)  "
          "peak %d  reaches resting at %s"
          % (rest_w, first, first_w, first_w / rest_w, peak_w, reach))
    print("    icon area: first %d  resting %.0f  smoothed peak %.0f (%.2fx)  ramp frames %d  "
          "half-work %.2f -> %s"
          % (areas[first], rest_a, peak_a, peak_a / max(1.0, rest_a), len(ramp), half,
             "decelerate" if half < 0.45 else ("accelerate" if half > 0.55 else "linear-ish")))

    # (a) STARTS AT NOTHING. The first icon the camera can see must be a SMALL
    # icon, not a full-size faint one -- which is exactly what the build before
    # this one draws, and the only place the two can be told apart.
    # SUPPORTING, not decisive, and the threshold says why. A full-size icon
    # fading up crosses the mask over a frame or two, so the build before this
    # one does not read 1.00 here -- measured 0.37 against 0.09-0.18 for the
    # grow, on the same rig and session (zrig/v1/). The arms that carry the
    # verdict are the RAMP and the DURATION below, which are 10x apart.
    if first_w > 0.30 * rest_w:
        print("FAIL the first icon on film is already %d of %d px wide -- it fades in at "
              "full size instead of growing from nothing (V1: \"start of animation - size 0\")"
              % (first_w, rest_w))
        fail = 1

    # (b) MONOTONICALLY NON-DECREASING, on the area series the spec names, read
    # against its own running maximum so one noisy frame is not a shrink.
    run_max = np.maximum.accumulate(sm[first:settle + 1])
    dips = [(first + k, sm[first + k], run_max[k]) for k in range(len(run_max))
            if sm[first + k] < 0.88 * run_max[k]]
    if dips:
        print("FAIL the icon shrinks during the open at %d frame(s), worst frame %d: %.0f px "
              "against %.0f already reached" % (len(dips), dips[0][0], dips[0][1], dips[0][2]))
        fail = 1

    # (c) FINISHES WITH THE OVERVIEW, not after it.
    if reach is None:
        print("FAIL the icon never reaches its resting size while the overview is open")
        fail = 1
    elif reach > settle + 1:
        print("FAIL the icon is still growing %d frames after the overview settled "
              "(reaches resting at %d, settle %d)" % (reach - settle, reach, settle))
        fail = 1

    # (d) ZERO OVERSHOOT, on the smoothed area: a bounce worth the name is 5-10%
    # of linear size, i.e. 10-20% of area, and the measured plateau holds inside
    # 4%.
    if peak_a > 1.12 * rest_a:
        print("FAIL the icon overshoots its resting size: smoothed peak area %.0f vs resting "
              "%.0f (%.2fx) -- entrances do not bounce" % (peak_a, rest_a, peak_a / rest_a))
        fail = 1

    # (a') THE GROWTH TAKES TIME. From the first icon on film to resting size:
    # 49 and 51 frames measured with the grow, 8 without it (the width the alpha
    # ramp alone produces). This is the same claim as (a) read as a duration
    # instead of a first value, and it does not depend on which frame happens to
    # cross the mask first.
    if reach is not None and reach - first < 20:
        print("FAIL the icon goes from first visible to full size in %d frames -- that is "
              "the alpha ramp of a full-size icon, not a size growing with the overview"
              % (reach - first))
        fail = 1

    # (e) A DECELERATING ENTRANCE, and a ramp long enough for "decelerating" to
    # mean anything. A step function has no half-work worth reading.
    if len(ramp) < 5:
        print("FAIL the icon spends %d frames between a fifth and four fifths of its size "
              "-- that is a step, not a growth" % len(ramp))
        fail = 1
    elif half >= 0.45:
        print("FAIL the growth does half its work at %.2f of its duration -- an entrance "
              "decelerates (house rule), so this must be under 0.45" % half)
        fail = 1

    return fail


def grade_reverse(rows, dump=False):
    """An open interrupted by a close. The icon must come back DOWN the track it
    went up. This is the arm a second timeline cannot pass: an icon running its
    own clock finishes growing, or pops off, while the overview is already
    leaving."""
    fail = 0
    drawn = [i for i, r in enumerate(rows) if r[1] > 0]
    if len(drawn) < 20:
        print("FAIL the fixture tile is in only %d frames -- rig fault" % len(drawn))
        return 1

    widths = [rows[i][2] for i in drawn]
    if dump:
        for k, i in enumerate(drawn):
            print("      %4d %-12s tile %4d  icon w %3d  area %5d"
                  % (k, rows[i][0], rows[i][1], widths[k], rows[i][3]))

    peak = max(widths)
    if peak < 20:
        print("FAIL the icon never grew at all (peak %d px) -- nothing was reversed" % peak)
        return 1

    top = widths.index(peak)
    up = [k for k in range(0, top + 1) if 0.2 * peak <= widths[k] <= 0.8 * peak]
    down = [k for k in range(top, len(widths)) if 0.2 * peak <= widths[k] <= 0.8 * peak]
    tail = widths[-3:]

    print("    reversal: peak %d px at frame %d of %d   up-ramp %d frames   "
          "down-ramp %d frames   tail %s" % (peak, top, len(widths), len(up), len(down), tail))

    if len(up) < 3:
        print("FAIL the icon does not grow through intermediate sizes on the way in "
              "(%d frames) -- the reversal caught nothing to reverse" % len(up))
        fail = 1
    if len(down) < 3:
        print("FAIL the icon does not come back DOWN through intermediate sizes (%d frames) "
              "-- it pops off instead of tracking the overview back" % len(down))
        fail = 1
    if max(tail) > 0.5 * peak:
        print("FAIL the icon is still %d px at the end of the close (peak %d) -- it did not "
              "follow the overview out" % (max(tail), peak))
        fail = 1
    return fail


if __name__ == "__main__":
    MODE = sys.argv[1]
    FRAMES = sys.argv[2]
    DUMP = "--dump" in sys.argv[3:]
    ROWS = series(FRAMES)
    RC = grade_open(ROWS, DUMP) if MODE == "open" else grade_reverse(ROWS, DUMP)
    print("PASS v1_icon %s" % MODE if not RC else "FAIL v1_icon %s" % MODE)
    sys.exit(RC)
