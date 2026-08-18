#!/usr/bin/env python3
"""V2 SUPER-hold window pill -- the pixel half. Runs IN THE GUEST.

Three modes, one per arm of scripts/gates/v2_super_pill/run.sh.

DOCTRINE, and every line of it is load-bearing here:
  * CONTROL FRAMES ON BOTH SIDES. The measured frame is bracketed by a
    no-SUPER frame before and a no-SUPER frame after, and the noise mask is
    built from THOSE TWO -- so the quickshell clock, the CPU readout and the
    big desktop clock widget are removed by measurement rather than by a
    hand-listed rectangle that a re-theme would silently move.
  * The mask is DILATED, because an anti-aliased digit edge moves by a pixel
    that the raw diff of two clock frames does not always contain.
  * The verdict is the LARGEST CONNECTED BLOB, never a bounding box: the box
    of "everything that changed" spans the bar AND the pill and would be
    ~2500 px wide in every frame, which is a check that cannot fail.
  * IDENTICAL FRAMES ARE AN EXPLICIT FAIL. A frozen capture proves nothing,
    and this guest's virtio-gpu hands back stale frames whenever no viewer is
    attached (see rig.sh, headless_on).

THE STRADDLE IS MEASURED, NOT ASSUMED. The user's sentence is "not entirely
over the window... but not entirely outside of it", and that is graded as four
inequalities against the fixture's own top-right corner -- the blob must cross
the top edge (some of it above, some below) and cross the right edge (some of
it outside, some inside). A pill drawn wholly inside the corner, or wholly
outside it, fails on the same numbers whichever way it went wrong.
"""
import sys
import os

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from blob import largest_of  # noqa: E402

DIFF = 30      # per-pixel channel-sum difference that counts as "changed"
DILATE = 5     # noise-mask dilation, px
BAR_H = 70     # the shell's top bar; masked outright as well as by the controls


def load(p):
    return np.asarray(Image.open(p).convert("RGB")).astype(int)


def dilate(mask, r):
    out = mask.copy()
    for d in range(1, r + 1):
        out[d:, :] |= mask[:-d, :]
        out[:-d, :] |= mask[d:, :]
        out[:, d:] |= mask[:, :-d]
        out[:, :-d] |= mask[:, d:]
    return out


def changed(a, b):
    return np.abs(a - b).sum(2) > DIFF


def measure(ctrl_a, meas, ctrl_b):
    """Largest blob of (meas - ctrl_a) with the two controls' own drift removed."""
    if np.array_equal(ctrl_a, ctrl_b) and np.array_equal(ctrl_a, meas):
        return None, "IDENTICAL FRAMES -- the capture pipeline is stale, this measures nothing"

    noise = dilate(changed(ctrl_a, ctrl_b), DILATE)
    noise[:BAR_H, :] = True
    m = changed(ctrl_a, meas) & ~noise
    found = largest_of(m)
    return found, None


def arm_straddle(argv):
    ctrl_a, meas, ctrl_b = (load(p) for p in argv[:3])
    fx, fy, fw, fh = (int(v) for v in argv[3:7])
    found, err = measure(ctrl_a, meas, ctrl_b)
    if err:
        print("FAIL straddle -- " + err)
        return 1

    if not found:
        print("FAIL straddle -- no blob at all: with SUPER held nothing appeared "
              "that is not also on both control frames (this is how the parent "
              "build fails, by absence)")
        return 1

    x, y, w, h, area = found
    right, bottom = x + w, y + h
    edge_x, edge_y = fx + fw, fy          # the window's top-right corner

    print("  blob   x %d..%d  y %d..%d  (%dx%d, ~%d px)" % (x, right, y, bottom, w, h, area))
    print("  corner x %d  y %d   (fixture %d,%d %dx%d)" % (edge_x, edge_y, fx, fy, fw, fh))

    bad = 0
    # It has to BE a pill and not a stray: the capsule is 112x40 at scale 1, so
    # anything under half that in either axis is something else that moved.
    if w < 56 or h < 20:
        print("  FAIL the blob is %dx%d -- too small to be the capsule (112x40 at scale 1)" % (w, h))
        bad = 1
    if area < 1500:
        print("  FAIL the blob is only ~%d px; a 112x40 capsule is ~4500" % area)
        bad = 1

    # THE STRADDLE, as four inequalities. Slack of 4 px on each so a rounded
    # capsule end or an anti-aliased edge cannot decide the verdict.
    if not y < edge_y - 4:
        print("  FAIL nothing of the pill is ABOVE the window's top edge (blob top %d, edge %d)"
              " -- it is entirely over the window" % (y, edge_y))
        bad = 1
    if not bottom > edge_y + 4:
        print("  FAIL nothing of the pill is BELOW the window's top edge (blob bottom %d, edge %d)"
              " -- it is entirely outside the window" % (bottom, edge_y))
        bad = 1
    if not right > edge_x + 4:
        print("  FAIL the pill does not reach past the window's right edge (blob right %d, edge %d)"
              % (right, edge_x))
        bad = 1
    if not x < edge_x - 4:
        print("  FAIL the pill starts past the window's right edge (blob left %d, edge %d)"
              " -- it is beside the window, not on its corner" % (x, edge_x))
        bad = 1

    if not bad:
        print("  straddle OK: %d px above the top edge / %d below, %d px past the right edge / %d inside"
              % (edge_y - y, bottom - edge_y, right - edge_x, edge_x - x))
    return bad


def arm_absent(argv):
    """The pill is NOT there. Same machinery, opposite verdict."""
    ctrl_a, meas, ctrl_b = (load(p) for p in argv[:3])
    label = argv[3]
    found, err = measure(ctrl_a, meas, ctrl_b)
    if err:
        print("FAIL %s -- %s" % (label, err))
        return 1
    if found and found[4] >= 1500:
        x, y, w, h, area = found
        print("  FAIL %s -- something %dx%d (~%d px) is drawn at %d,%d that should not be"
              % (label, w, h, area, x, y))
        return 1
    print("  %s OK (largest residue ~%d px)" % (label, found[4] if found else 0))
    return 0


def arm_motion(argv):
    """Entrance and exit spans off a film, inside the pill's own box.

    The window under the pill is a kitty holding a cleared screen and the
    wallpaper is pinned, so inside this box the ONLY thing that changes is the
    pill -- no mask is needed here.

    THE OBSERVABLE IS THE MEAN ABSOLUTE DIFFERENCE, NOT A PIXEL COUNT, and that
    is a correction rather than a preference. The first cut of this arm counted
    pixels differing by more than a threshold, which is a THRESHOLD CROSSING and
    not the alpha: once the capsule is ~15% opaque nearly every pixel under it
    is already over the threshold, so the count saturates in the first fifth of
    the entrance and empties in the last fifth of the exit. Measured that way
    the 140 ms entrance read 300 ms and the 105 ms exit read 450 ms -- the
    curves' own shapes, inverted, presented as durations. The mean difference is
    proportional to the alpha the pill is drawn at, so it IS the reveal.

    The shape is graded too, and by the same number both ways: houseEase
    decelerates on the way in and accelerates on the way out, so the curve sits
    ABOVE its own chord in both directions -- at the midpoint of either span the
    value must be more than half of peak. A linear ramp sits ON the chord and a
    curve of the wrong direction sits under it.
    """
    d = argv[0]
    px, py, pw, ph = (int(v) for v in argv[1:5])
    budget_ms = float(argv[5])
    fps = float(argv[6]) if len(argv) > 6 else 60.0

    frames = sorted(f for f in os.listdir(d) if f.endswith(".png"))
    if len(frames) < 20:
        print("FAIL motion -- only %d frames; the film is too short to grade" % len(frames))
        return 1

    ref = load(os.path.join(d, frames[0]))[py:py + ph, px:px + pw]
    vals = []
    for f in frames:
        a = load(os.path.join(d, f))[py:py + ph, px:px + pw]
        vals.append(float(np.abs(a - ref).mean()))

    peak = max(vals)
    if peak < 6.0:
        print("FAIL motion -- the pill never appeared in its own box (peak mean diff %.1f)" % peak)
        return 1
    if len(set(vals)) == 1:
        print("FAIL motion -- every frame is identical; a frozen capture proves nothing")
        return 1

    # TWO SPANS, MEASURING TWO DIFFERENT THINGS, and the reason there are two is
    # that no single percentile window can answer both questions here.
    #
    # APPEAR (floor -> 95% of settled) is what the user's criterion is about:
    # "pill appears <=150 ms after SUPER down" is a statement about when it is
    # THERE, and a capsule at 95% opacity is there. It is deliberately NOT the
    # nominal duration -- the house decel bezier is cubic-bezier(.16,1,.3,1),
    # whose last 5% of travel occupies half its duration, so time-to-95% is
    # about half of IN_MS and this arm says so rather than pretending otherwise.
    # The constants are IN_MS 140 / OUT_MS 105 in WindowPill.cpp; this arm bounds
    # what they FEEL like, and the ratio below is what checks the numbers.
    #
    # RATIO is taken off the 10-90% windows instead, and that IS shape-free
    # here: the house curves are exact mirrors -- decel (.16,1,.3,1) and accel
    # (.7,0,.84,0) -- so the same value band occupies the same fraction of each
    # one's duration (0.32, by construction). The ratio of the two windows is
    # therefore the ratio of the two durations, 105/140, and nothing about the
    # curve enters it.
    #
    # The floor is the FILM'S OWN noise floor, not a fixed fraction. wf-recorder
    # writes h264, so two frames of an identical scene are not identical bytes:
    # measured, a settled "the pill is gone" frame sits ~3.5% of peak away from
    # the reference and a flat 3% floor made the exit look like it never
    # finished. The pre-SUPER frames are exactly that residue with nothing else
    # in them, so they measure it.
    base = float(np.median(vals[:20]))
    floor, ceil = base + 0.04 * peak, 0.95 * peak
    lo, hi = 0.10 * peak, 0.90 * peak

    rise = next(i for i, c in enumerate(vals) if c >= ceil)
    up0 = max([i for i in range(rise) if vals[i] <= floor] or [0])
    top = max(i for i, c in enumerate(vals) if c >= ceil)
    try:
        dn = next(i for i in range(top, len(vals)) if vals[i] <= floor)
    except StopIteration:
        print("FAIL motion -- the pill never went away again (peak %.1f, last %.1f)" % (peak, vals[-1]))
        return 1

    ms = 1000.0 / fps
    up_ms, dn_ms = (rise - up0) * ms, (dn - top) * ms
    w_up = (next(i for i, c in enumerate(vals) if c >= hi) - next(i for i, c in enumerate(vals) if c > lo)) * ms
    w_dn = (next(i for i in range(top, len(vals)) if vals[i] <= lo) - max(i for i, c in enumerate(vals) if c >= hi)) * ms
    up_mid = vals[(up0 + rise) // 2] / peak
    dn_mid = vals[(top + dn) // 2] / peak
    print("  frames %d at %.1f fps  peak mean diff %.1f" % (len(frames), fps, peak))
    print("  appear   frames %d..%d  = %.0f ms to 95%% opacity   midpoint %.2f of peak" % (up0, rise, up_ms, up_mid))
    print("  leave    frames %d..%d  = %.0f ms back to nothing   midpoint %.2f of peak" % (top, dn, dn_ms, dn_mid))
    print("  windows  entrance 10-90%% %.0f ms   exit 90-10%% %.0f ms" % (w_up, w_dn))

    bad = 0
    if up_ms > budget_ms:
        print("  FAIL it took %.0f ms to reach 95%% opacity, budget %.0f (V2: 'pill appears <=150ms"
              " after SUPER down')" % (up_ms, budget_ms))
        bad = 1
    if w_dn >= w_up:
        print("  FAIL the exit window (%.0f ms) is not shorter than the entrance window (%.0f ms) --"
              " house rule, exits accelerate and run 20-30%% shorter" % (w_dn, w_up))
        bad = 1
    else:
        cut = 100.0 * (1.0 - w_dn / w_up)
        print("  exit is %.0f%% shorter than the entrance (house rule: 20-30%%)" % cut)
        # A window is bounded by two frames at each end, so it carries +-2
        # frames = +-%.0f ms of quantisation; on the ~340 ms exit window that is
        # +-10 points of this percentage on its own. The band is 25% +- 13.
        if cut < 12.0 or cut > 40.0:
            print("  FAIL that is outside the 20-30%% band even allowing two frames of quantisation"
                  " on each window (+-%.0f ms)" % (2 * ms))
            bad = 1
    if up_mid <= 0.5:
        print("  FAIL the entrance sits at %.2f of peak halfway through: that is a linear ramp or an"
              " accelerating one, not a decelerating entrance" % up_mid)
        bad = 1
    if dn_mid <= 0.5:
        print("  FAIL the exit sits at %.2f of peak halfway through: that is a linear fade or a"
              " decelerating one, not an accelerating exit" % dn_mid)
        bad = 1
    return bad


def arm_overview(argv):
    """The hovered tile wears the PILL instead of the close-X while SUPER is held.

    The cursor does not move between the three shots: the hover blow-up, the
    caption and the tile itself are therefore identical in all of them, and the
    only thing SUPER changes is which chrome sits on the corner. The verdict is
    a WIDTH: the close-X is a disc of at most 32 px, the capsule is 112.
    """
    hx, hp, hx2 = (load(p) for p in argv[:3])
    found, err = measure(hx, hp, hx2)
    if err:
        print("FAIL overview -- " + err)
        return 1
    if not found:
        print("FAIL overview -- SUPER changed nothing on the hovered tile (this is how the"
              " parent build fails, by absence)")
        return 1

    x, y, w, h, area = found
    print("  blob   x %d..%d  y %d..%d  (%dx%d, ~%d px)" % (x, x + w, y, y + h, w, h, area))
    if w < 80:
        print("  FAIL the chrome that changed is only %d px wide; the close-X it replaces is at"
              " most 32 and the capsule is 112, so this is not a pill" % w)
        return 1
    if h < 24:
        print("  FAIL the chrome that changed is only %d px tall (the capsule is 40)" % h)
        return 1
    print("  overview OK: %d px of chrome swapped in on the corner, three times the X's width" % w)
    return 0


ARMS = {"straddle": arm_straddle, "absent": arm_absent, "motion": arm_motion, "overview": arm_overview}

if __name__ == "__main__":
    sys.exit(ARMS[sys.argv[1]](sys.argv[2:]))
