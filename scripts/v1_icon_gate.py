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

THE TILE IS ALSO THE CLOCK, TWICE OVER.
    (1) The tile's drawn box is a function of the same open progress the icon
        rides, so the frame the tile stops moving IS the frame the overview
        settles -- no second instrument.
    (2) The tile's drawn width is also the RENDER CLOCK. See below.


=============================================================================
THE FILM LIES, AND IT LIES TWICE (V4, 2026-08-18)
=============================================================================

wf-recorder is asked for `-r 60` and writes `Framerate: 60` into its log. That
number is a REQUEST. It is wrong in two different ways at once, and the first
cut of this gate believed both.

  LIE 1 -- THE RATE.  The container's rate is whatever came out, not what was
  asked for. Measured on four films of this same fixture: 60.16, 60.20, 60.28
  Hz -- close here, but nothing in the rig guarantees it, and every threshold
  in this file used to be a FRAME COUNT. A frame count is only a duration if
  you know the rate. So the rate is now MEASURED off the container
  (nb_frames / duration, passed in as --fps) and every threshold in this file
  is expressed in MILLISECONDS.

  LIE 2 -- THE FRAMES, and this one is the one that mattered.  wf-recorder's
  `fps=60` filter is a CONSTANT-RATE filter: when the compositor draws nothing,
  it DUPLICATES the last frame to keep the cadence. Those duplicates are not
  measurements. They are the same measurement, stamped again.

  On this guest the overview's CLOSE is drawn at roughly 4-24 Hz -- an order of
  magnitude under the capture rate -- so a 270 ms close arrives as 2 to 6 real
  frames padded out to 19-27. The old grader counted the padding:

      film                     descent frames   REAL renders   band   REAL
      V1-old   (the defect)          27              6           0      0
      V1-new   (certified PASS)      25              6          23      4
      tip 08-18 before rig fix       19              2           0      0
      tip 08-18 after  rig fix       27              2          21      1

  V1's certified "down-ramp 23 frames" was 4 real frames and 19 copies of one
  of them. The tip's "down-ramp 0" and, an hour later, "down-ramp 21" were the
  SAME single rendered frame, 30 px wide one run and 31 px the next, landing
  either side of a 0.8*peak = 28.8-30.4 px ceiling. PASS and FAIL on this arm
  have never once been decided by the compositor; they were decided by which
  side of a threshold one duplicated frame fell on.

  So: THE RENDER CLOCK. The tile's drawn width changes on every frame the
  compositor actually produced during motion, and cannot change on a frame it
  did not produce. A frame whose tile width equals its predecessor's is a
  REPEAT and contributes elapsed time but no evidence. Every count in this file
  is a count of RENDERS. The clock UNDERcounts where motion is slow, which is
  the safe direction: it declares a span unmeasurable rather than grading it.

  AND: A SPAN WITH TOO FEW RENDERS IS NOT GRADED AT ALL. It is reported as
  RIG / UNGRADED, never as FAIL -- y8's rule, that a non-measurement is not a
  verdict. A decisive arm that cannot be graded exits 3 (the suite's SKIP) and
  says why; a supporting arm that cannot be graded prints UNGRADED and stands
  aside while the rest of the gate returns a verdict.

WHAT CARRIES THE VERDICT NOW. P1's open is drawn densely (60-plus renders
across the ramp) and is graded as before, in ms. P2's descent is the arm that
has never once been a measurement on this guest, so it is demoted to
rig-gated-supporting, and P2's claim is carried instead by two arms that no
capture rate can touch:

    PEAK RATIO   the largest icon on a film of an open interrupted 250 ms into
                 a 2 s open. An icon riding the overview's progress is a
                 fraction of its resting size; one drawn full-size and faded is
                 all of it. A MAX over the film -- immune to how many frames
                 were drawn, and to where a freeze lands.
                     V1-old 0.985    tip 0.529 / 0.559 / 0.559
    UP-RAMP      how long the icon spends passing through intermediate sizes on
                 the way IN, counted in RENDERS and read as ms.
                     V1-old 1 render    tip 5 / 6 / 6 renders

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

# ---------------------------------------------------------------- rig floors
# A span with fewer real renders than this is not a measurement of a curve; it
# is one or two samples of one. Chosen against the four films in the docstring:
# every up-ramp measured 8-10 renders and is gradeable on all four; the descent
# measured 2-6 and is gradeable on two.
MIN_RENDERS_SPAN = 5
# ...and inside the graded band, this many renders before a duration is claimed.
MIN_RENDERS_BAND = 3
# The open is a 2 s animation filmed at 60 Hz. Anything under this many renders
# across it and the film is not of an animation.
MIN_RENDERS_OPEN = 25

# The reversal is issued 250 ms into a 2 s open. An icon that rides the open's
# progress is a fraction of its resting size at that moment; one that is drawn
# at full size and faded up is all of it. Measured 0.53-0.56 for the grow and
# 0.985 for the fade, so the ceiling sits in the gap and nowhere near either.
REVERSE_PEAK_MAX = 0.75


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


# --------------------------------------------------------------- the clocks
def film_fps(argv, frames):
    """The film's MEASURED rate, or None.

    Passed in by run.sh as `--fps N`, read off the container with ffprobe
    (nb_frames / duration). Never wf-recorder's `-r`, and never the `Framerate:`
    line in its log -- both are the request, not the result.
    """
    for i, a in enumerate(argv):
        if a == "--fps" and i + 1 < len(argv):
            try:
                v = float(argv[i + 1])
                return v if v > 1 else None
            except ValueError:
                return None
    return None


def renders_in(tilew, lo, hi):
    """Indices in [lo, hi] on which the compositor drew a NEW frame.

    The tile's box is a continuous function of the open progress, so during
    motion its drawn width advances on every frame the compositor produced --
    and cannot advance on one it did not. A frame whose tile width repeats its
    predecessor's is wf-recorder's `fps=` filter padding the cadence.

    Undercounts where the motion is slower than a pixel per frame. That is the
    safe direction: the span is then reported unmeasurable rather than graded.
    """
    hi = min(hi, len(tilew) - 1)
    if hi < lo:
        return []
    return [lo] + [k for k in range(lo + 1, hi + 1) if tilew[k] != tilew[k - 1]]


class Rig(Exception):
    """A span the film does not contain enough renders to grade."""


def ms(frames_count, fps):
    return 1000.0 * frames_count / fps


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


def grade_open(rows, fps, dump=False, restfile=None):
    fail = 0
    rig = 0
    drawn = [i for i, r in enumerate(rows) if r[1] > 0]
    if ms(len(drawn), fps) < 300:
        print("RIG the fixture tile is in only %d frames (%.0f ms) -- nothing to grade"
              % (len(drawn), ms(len(drawn), fps)))
        return 0, 1

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
        return 1, 0

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
        print("RIG the film never caught the open MOVING and then STOPPED "
              "(first move %s, settle %d of %d) -- no controls on either side"
              % (moved[0] if moved else None, settle, len(tilew)))
        return 0, 1
    if settle > len(tilew) - 6:
        print("FAIL the film ended while the overview was still opening (settle %d of %d)"
              % (settle, len(tilew)))
        fail = 1

    # THE RENDER CLOCK across the open. Not "distinct widths" -- the count of
    # frames the compositor actually produced, which is what a duration divided
    # by a capture rate is only a proxy for.
    open_renders = renders_in(tilew, moved[0], settle)
    open_hz = len(open_renders) / max(1e-3, ms(settle - moved[0] + 1, fps) / 1000.0)
    if len(open_renders) < MIN_RENDERS_OPEN:
        print("RIG the compositor drew only %d frames across the %.0f ms open (%.1f Hz) -- "
              "the capture is repeating frames, not filming motion"
              % (len(open_renders), ms(settle - moved[0] + 1, fps), open_hz))
        return 0, 1

    rest_w = int(np.median([w for w in widths[settle:] if w > 0] or [0]))
    rest_a = float(np.median([a for a in areas[settle:] if a > 0] or [0]))
    if rest_w < 30:
        print("RIG no icon at rest (%d px) -- the gate is not photographing an icon" % rest_w)
        return 0, 1
    if restfile:
        # P2 needs the resting size and can never reach it: its open is cut off
        # a quarter of a second in. Same session, same fixture, same frame.
        with open(restfile, "w") as fh:
            fh.write("%d\n" % rest_w)

    seen = [k for k in range(len(widths)) if widths[k] > 0]
    first, first_w = seen[0], widths[seen[0]]

    sm = smooth(areas)
    ramp = [k for k in seen if 0.2 * rest_w <= widths[k] <= 0.8 * rest_w]
    ramp_renders = [k for k in renders_in(tilew, ramp[0], ramp[-1]) if k in set(ramp)] if ramp else []
    reach = next((k for k in range(len(widths)) if widths[k] >= rest_w - 2), None)
    peak_w, peak_a = max(widths), float(sm.max())
    grow = widths[first:(reach if reach is not None else settle) + 1]
    half = half_work(grow) if len(grow) > 2 else 1.0

    print("    frames %d  tile drawn %d  measured %.2f fps  first move %d  overview settle %d  "
          "control max %d px" % (len(rows), len(drawn), fps, moved[0], settle, max(control)))
    print("    render clock: %d frames drawn across the open (%.1f Hz of a %.0f ms animation)"
          % (len(open_renders), open_hz, ms(settle - moved[0] + 1, fps)))
    print("    icon width: resting %d  first seen at frame %d = %d px (%.2f of resting)  "
          "peak %d  reaches resting at %s"
          % (rest_w, first, first_w, first_w / rest_w, peak_w, reach))
    print("    icon area: first %d  resting %.0f  smoothed peak %.0f (%.2fx)  ramp %d renders "
          "/ %.0f ms  half-work %.2f -> %s"
          % (areas[first], rest_a, peak_a, peak_a / max(1.0, rest_a), len(ramp_renders),
             ms(len(ramp), fps), half,
             "decelerate" if half < 0.45 else ("accelerate" if half > 0.55 else "linear-ish")))

    # (a) STARTS AT NOTHING. The first icon the camera can see must be a SMALL
    # icon, not a full-size faint one -- which is exactly what the build before
    # this one draws, and the only place the two can be told apart.
    # SUPPORTING, not decisive, and the threshold says why. A full-size icon
    # fading up crosses the mask over a frame or two, so the build before this
    # one does not read 1.00 here -- measured 0.37 against 0.01-0.18 for the
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

    # (c) FINISHES WITH THE OVERVIEW, not after it. One frame of slack, in ms.
    if reach is None:
        print("FAIL the icon never reaches its resting size while the overview is open")
        fail = 1
    elif ms(reach - settle, fps) > 1.5 * ms(1, fps):
        print("FAIL the icon is still growing %.0f ms after the overview settled "
              "(reaches resting at %d, settle %d)" % (ms(reach - settle, fps), reach, settle))
        fail = 1

    # (d) ZERO OVERSHOOT, on the smoothed area: a bounce worth the name is 5-10%
    # of linear size, i.e. 10-20% of area, and the measured plateau holds inside
    # 4%.
    if peak_a > 1.12 * rest_a:
        print("FAIL the icon overshoots its resting size: smoothed peak area %.0f vs resting "
              "%.0f (%.2fx) -- entrances do not bounce" % (peak_a, rest_a, peak_a / rest_a))
        fail = 1

    # (a') THE GROWTH TAKES TIME. From the first icon on film to resting size:
    # 750-816 ms measured with the grow, 133 ms without it (the width the alpha
    # ramp alone produces). This is the same claim as (a) read as a duration
    # instead of a first value, and it does not depend on which frame happens to
    # cross the mask first -- nor, now, on the capture rate.
    if reach is not None and ms(reach - first, fps) < 333:
        print("FAIL the icon goes from first visible to full size in %.0f ms -- that is "
              "the alpha ramp of a full-size icon, not a size growing with the overview"
              % ms(reach - first, fps))
        fail = 1

    # (e) A DECELERATING ENTRANCE, and a ramp long enough for "decelerating" to
    # mean anything. A step function has no half-work worth reading. Graded on
    # RENDERS: 22-26 real frames measured with the grow, 2 without it.
    if len(ramp_renders) < MIN_RENDERS_BAND:
        print("RIG the compositor drew only %d frames while the icon was between a fifth "
              "and four fifths of its size -- too few to call it a growth or a step"
              % len(ramp_renders))
        rig = 1
    elif ms(len(ramp), fps) < 83:
        print("FAIL the icon spends %.0f ms between a fifth and four fifths of its size "
              "-- that is a step, not a growth" % ms(len(ramp), fps))
        fail = 1
    elif half >= 0.45:
        print("FAIL the growth does half its work at %.2f of its duration -- an entrance "
              "decelerates (house rule), so this must be under 0.45" % half)
        fail = 1

    return fail, rig


def grade_reverse(rows, fps, dump=False, rest_w=None):
    """An open interrupted by a close, 250 ms into a 2 s open.

    THE CLAIM: the icon is not running a clock of its own. An icon on its own
    timeline is at (or near) its resting size a quarter of a second in, because
    the build before this one draws it full-size and fades it; an icon riding
    the overview's progress is barely half that.

    The descent -- "and it comes back DOWN the same track" -- is the arm this
    guest has never actually filmed: see the module docstring. It is graded when
    the film contains enough renders to grade it, and stands aside, loudly, when
    it does not.
    """
    fail = 0
    rig = 0
    drawn = [i for i, r in enumerate(rows) if r[1] > 0]
    if ms(len(drawn), fps) < 300:
        print("RIG the fixture tile is in only %d frames (%.0f ms)" % (len(drawn), ms(len(drawn), fps)))
        return 0, 1

    tilew = [rows[i][1] for i in drawn]
    widths = [rows[i][2] for i in drawn]
    if dump:
        for k, i in enumerate(drawn):
            print("      %4d %-12s tile %4d  icon w %3d  area %5d"
                  % (k, rows[i][0], tilew[k], widths[k], rows[i][3]))

    peak = max(widths)
    if peak < 20:
        print("RIG the icon never grew at all (peak %d px) -- nothing was reversed" % peak)
        return 0, 1

    top = widths.index(peak)
    seen = [k for k in range(len(widths)) if widths[k] > 0]
    first = seen[0]
    last = seen[-1]
    tail = widths[-3:]

    up_renders = renders_in(tilew, first, top)
    up_band = [k for k in range(first, top + 1) if 0.2 * peak <= widths[k] <= 0.8 * peak]
    up_band_r = [k for k in up_band if k in set(up_renders)]

    dn_renders = renders_in(tilew, top, last)
    dn_band = [k for k in range(top, last + 1) if 0.2 * peak <= widths[k] <= 0.8 * peak]
    dn_band_r = [k for k in dn_band if k in set(dn_renders)]

    print("    reversal: measured %.2f fps   peak %d px at frame %d of %d   resting %s"
          % (fps, peak, top, len(widths), rest_w if rest_w else "unknown"))
    print("    render clock: %d drawn on the way up (%d in band), %d on the way down "
          "(%d in band)  tail %s"
          % (len(up_renders), len(up_band_r), len(dn_renders), len(dn_band_r), tail))

    # (i) PEAK RATIO -- THE ARM NO CAPTURE RATE CAN TOUCH. A max over the whole
    # film: it does not care how many frames were drawn, only how big the
    # biggest one was. V1-old 0.985, this build 0.529-0.559.
    if rest_w:
        ratio = peak / float(rest_w)
        print("    peak is %.3f of resting (%d of %d px) -- ceiling %.2f"
              % (ratio, peak, rest_w, REVERSE_PEAK_MAX))
        if ratio > REVERSE_PEAK_MAX:
            print("FAIL a quarter of a second into a 2 s open the icon is already %.0f%% of "
                  "its resting size -- it is not riding the overview's progress, it is "
                  "drawn full size and faded" % (100 * ratio))
            fail = 1
    else:
        print("RIG no resting size from P1 -- the peak-ratio arm, which is the one arm no "
              "capture rate can touch, cannot be graded")
        rig = 1

    # (ii) UP-RAMP through intermediate sizes, counted in RENDERS. V1-old drew
    # ONE such frame (14 px, then 55 px on the very next drawn frame); this
    # build draws 5-6.
    if len(up_renders) < MIN_RENDERS_SPAN:
        print("RIG the compositor drew only %d frames on the way up -- too few to say "
              "whether the icon passed through intermediate sizes" % len(up_renders))
        rig = 1
    elif len(up_band_r) < MIN_RENDERS_BAND:
        print("FAIL the icon was drawn %d time(s) between a fifth and four fifths of its "
              "peak on the way in, out of %d frames the compositor drew -- it jumps to "
              "full size instead of growing" % (len(up_band_r), len(up_renders)))
        fail = 1

    # (iii) IT LEAVES WITH THE OVERVIEW. Rate-immune: the last frames of the
    # film are the desktop, and the icon is not on them.
    if max(tail) > 0.5 * peak:
        print("FAIL the icon is still %d px at the end of the close (peak %d) -- it did not "
              "follow the overview out" % (max(tail), peak))
        fail = 1

    # (iv) THE DESCENT. Supporting, and rig-gated, because a 250 ms close drawn
    # at 4-24 Hz is 2-6 real frames -- see the module docstring for the four
    # films where this arm's verdict was decided by a duplicate.
    if len(dn_renders) < MIN_RENDERS_SPAN:
        print("    UNGRADED (rig): the compositor drew %d frames across the whole close, "
              "under the floor of %d -- the descent is not graded on this film. The verdict "
              "above rests on the peak ratio and the up-ramp."
              % (len(dn_renders), MIN_RENDERS_SPAN))
    elif len(dn_band_r) < MIN_RENDERS_BAND:
        print("FAIL of the %d frames the compositor drew during the close, %d caught the icon "
              "between a fifth and four fifths of its peak -- it pops off instead of tracking "
              "the overview back down" % (len(dn_renders), len(dn_band_r)))
        fail = 1

    return fail, rig


if __name__ == "__main__":
    MODE = sys.argv[1]
    FRAMES = sys.argv[2]
    DUMP = "--dump" in sys.argv[3:]
    FPS = film_fps(sys.argv, FRAMES)
    if FPS is None:
        print("RIG no measured fps for this film -- run.sh must pass --fps from ffprobe; "
              "wf-recorder's own rate is a request, not a result")
        sys.exit(3)

    RESTW = None
    for i, a in enumerate(sys.argv):
        if a == "--resting" and i + 1 < len(sys.argv):
            try:
                RESTW = int(sys.argv[i + 1])
            except ValueError:
                RESTW = None
    RESTFILE = None
    for i, a in enumerate(sys.argv):
        if a == "--write-resting" and i + 1 < len(sys.argv):
            RESTFILE = sys.argv[i + 1]

    ROWS = series(FRAMES)
    if MODE == "open":
        RC, RIGRC = grade_open(ROWS, FPS, DUMP, RESTFILE)
    else:
        RC, RIGRC = grade_reverse(ROWS, FPS, DUMP, RESTW)

    # A real failure outranks a rig fault: a span that WAS graded and came back
    # wrong is a verdict, and an ungradeable neighbour does not excuse it.
    if RC:
        print("FAIL v1_icon %s" % MODE)
        sys.exit(1)
    if RIGRC:
        print("RIG v1_icon %s -- a decisive arm could not be graded on this film" % MODE)
        sys.exit(3)
    print("PASS v1_icon %s" % MODE)
    sys.exit(0)
