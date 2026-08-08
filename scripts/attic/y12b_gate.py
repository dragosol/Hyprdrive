#!/usr/bin/env python3
"""Y12(b) gate: is the dock's frost the same frost a window gets?

Reads one frame that contains, over one striped backdrop:
  * the translucent test window at a known box   (Hyprland's own window frost)
  * the dock pill                                (the plugin's chrome frost)

The backdrop has FINE bars on the left half and COARSE bars on the right, so
each plate can be scored twice:

  FINE/COARSE ratio   falls as blur RADIUS grows, and is unaffected by tint
  COARSE vs backdrop  falls as TINT grows, and is barely touched by blur

Two plates, two numbers each. If the ratios match and the coarse levels do not,
the difference the user cannot find is TINT, which is exactly the hypothesis
7afcf63 wrote down and could not test.

usage: y12b_gate.py <dir> <tag> <desktop|overview>
"""
import sys

import numpy as np
from PIL import Image

SMOOTH = 41  # px; separates "fine" from "coarse" -- between the two periods


def lum(a):
    return a.mean(axis=2)


def movavg(p, n):
    k = np.ones(n) / n
    return np.convolve(p, k, mode="same")


def amps(profile):
    """(fine, coarse) amplitude of a 1-D luminance profile."""
    slow = movavg(profile, SMOOTH)
    fast = profile - slow
    trim = SMOOTH  # the convolution's edges are not real signal
    return float(fast[trim:-trim].std()), float(slow[trim:-trim].std())


def band(img, y0, y1, x0, x1):
    return lum(img[y0:y1, x0:x1].astype(np.float64)).mean(axis=0)


def find_pill(img, mid):
    """The pill, found from the frost itself -- the thing the gate is about --
    rather than from brightness, which a bright wallpaper defeats.

    ONLY IN THE FINE HALF. The coarse half is quiet by construction: it has no
    fine bars to smooth away, so a whole-width search returns the entire right
    of the screen and calls it a plate. So the left edge is found among the fine
    bars and the right edge is taken by SYMMETRY -- baseLayout centres the pill
    on the monitor, which is a property of the layout rather than a guess (and
    the independent pillbox.py reading, 924..1635 on 2560, is centred to half a
    pixel).
    """
    h, w = img.shape[:2]
    # The bottom 90 rows, not 200. The pill is ~82 rows tall, so averaging over
    # 200 mixes in 120 rows of SHARP bars above it and the plate's signature
    # washes out entirely -- the first cut found no pill at all for that reason.
    TALL = 90
    region = lum(img[h - TALL:, :mid].astype(np.float64))
    col = region.mean(axis=0)
    fine = np.abs(col - movavg(col, 9))
    thresh = np.median(fine) * 0.5
    quiet = fine < thresh

    # The run that reaches the midline: that is the pill's left half. Started 40
    # columns short of the midline, because the fine/coarse boundary itself is a
    # discontinuity -- the column right on it reads as loud whatever the plate
    # does, and a scan begun there stops immediately and reports no pill.
    i = len(quiet) - 41
    while i >= 0 and quiet[i]:
        i -= 1
    px0 = i + 1
    if mid - px0 < 100:
        return None
    px1 = w - px0

    # The VERTICAL scan needs a taller window than the column scan did, and for
    # the opposite reason: its reference rows must be OUTSIDE the pill. Taking
    # the baseline from the top of a 90-row band read the plate's own quiet as
    # "normal" and then found no plate anywhere in it.
    DEEP = 260
    sub = lum(img[h - DEEP:, px0 + 20:mid - 20].astype(np.float64))

    # PER ROW, AT THE BARS' OWN FREQUENCY, not a broadband residue. The icons
    # are high-contrast and a broadband measure scores them within 10% of the raw
    # bars, so a threshold between the two does not exist -- the scan stopped
    # inside the icon row and reported a 26px pill. The bars are PERIODIC and the
    # icons are not, so one FFT bin separates them completely.
    def at_bar_freq(rows):
        n = rows.shape[1]
        win = np.hanning(n)
        mag = np.abs(np.fft.rfft((rows - rows.mean(axis=1, keepdims=True)) * win, axis=1)) / (n / 4.0)
        lo = max(3, n // 200)
        k = int(np.argmax(mag[:, lo:len(mag[0]) // 2].sum(axis=0))) + lo
        return mag[:, k]

    rowfine = at_bar_freq(sub)

    # THE PILL'S TOP EDGE IS WHERE THE RAW BARS STOP. Not "the quietest run",
    # which picked the TEST WINDOW twice: the window is frosted too, so it is
    # just as quiet, and it sits higher up the same strip. And not "the quiet run
    # at the bottom" either, because the ICONS are loud and split the pill's own
    # rows into short pieces.
    #
    # Raw bars are the loudest thing in the strip by a wide margin -- louder than
    # icons, which are not periodic at this scale -- so the LAST row above the
    # 60% mark is the last row of backdrop, and the plate starts under it. The
    # bottom edge is EDGE_MARGIN, which the layout fixes at 4px.
    loud = np.percentile(rowfine, 90)
    hot = np.where(rowfine > loud * 0.6)[0]
    if not len(hot):
        return None
    py0 = h - DEEP + int(hot.max()) + 1
    py1 = h - 4
    if py1 - py0 < 30:
        return None
    return px0, px1, py0, py1


def main():
    d, tag, which = sys.argv[1], sys.argv[2], sys.argv[3]
    img = np.asarray(Image.open("%s/%s-%s.png" % (d, tag, which)).convert("RGB"))
    h, w = img.shape[:2]
    mid = w // 2
    tx, ty, tw, th = [int(v) for v in open("%s/%s-win.txt" % (d, tag)).read().split()]

    # RAW BACKDROP, well clear of both plates.
    bg = band(img, 200, 260, 0, w)
    bg_fine, _ = amps(bg[:mid])
    _, bg_coarse = amps(bg[mid:])
    print("backdrop      fine %8.3f   coarse %8.3f" % (bg_fine, bg_coarse))
    if bg_fine < 3 or bg_coarse < 3:
        print("ABORT: the backdrop has no bars to speak of -- fixture fault")
        return 2

    # THE WINDOW, a strip inside it and clear of its own edges.
    wy0, wy1 = ty + 40, ty + th - 40
    win = band(img, wy0, wy1, tx + 30, tx + tw - 30)
    n = len(win)
    w_fine, _ = amps(win[: n // 2])
    w_noise, w_coarse = amps(win[n // 2:])

    pill = find_pill(img, mid)
    if pill is None:
        print("ABORT: could not find the pill by its frost")
        return 2
    px0, px1, py0, py1 = pill
    print("pill found    x %d..%d  y %d..%d" % (px0, px1, py0, py1))

    # The plate ABOVE the icons: the pill's own top rows, which are plate and
    # nothing else across its whole width.
    ry0, ry1 = py0 + 4, min(py0 + 16, py1)
    pil = band(img, ry0, ry1, px0 + 20, px1 - 20)
    m = len(pil)
    p_fine, _ = amps(pil[: m // 2])
    p_noise, p_coarse = amps(pil[m // 2:])

    # THE NOISE FLOOR, free and per-plate: the coarse half has no fine bars in
    # it, so whatever fine-scale amplitude survives there is measurement noise
    # under that exact plate. Without it a fine reading of 0.3 and one of 1.7
    # are both "nearly nothing" and the comparison is unreadable.
    print("window        fine %8.3f   coarse %8.3f   noise floor %6.3f" % (w_fine, w_coarse, w_noise))
    print("pill          fine %8.3f   coarse %8.3f   noise floor %6.3f" % (p_fine, p_coarse, p_noise))
    print("fine above own floor:  window %.2fx   pill %.2fx" % (w_fine / max(w_noise, 1e-6), p_fine / max(p_noise, 1e-6)))

    w_ratio = w_fine / max(w_coarse, 1e-6)
    p_ratio = p_fine / max(p_coarse, 1e-6)
    w_tint = w_coarse / bg_coarse
    p_tint = p_coarse / bg_coarse

    print()
    print("BLUR RADIUS  (fine/coarse, tint-independent)   window %.4f   pill %.4f" % (w_ratio, p_ratio))
    print("TINT         (coarse kept, blur-independent)   window %.4f   pill %.4f" % (w_tint, p_tint))

    def rel(a, b):
        return abs(a - b) / max(a, b, 1e-6)

    blur_same = rel(w_ratio, p_ratio) < 0.25
    tint_same = rel(w_tint, p_tint) < 0.15

    print()
    print("blur radius matches : %s (%.0f%% apart)" % ("yes" if blur_same else "NO", rel(w_ratio, p_ratio) * 100))
    print("tint matches        : %s (%.0f%% apart)" % ("yes" if tint_same else "NO", rel(w_tint, p_tint) * 100))

    if blur_same and tint_same:
        print("\nY12(b) PASS -- the dock's frost is the window's frost")
        return 0
    if blur_same and not tint_same:
        print("\nY12(b) FAIL, and the difference is TINT, not blur.")
        print("The pill keeps %.0f%% of the backdrop where the window keeps %.0f%%." % (p_tint * 100, w_tint * 100))
        print("This is 7afcf63's written hypothesis, now measured.")
        return 1
    print("\nY12(b) FAIL -- the blur radii differ")
    return 1


if __name__ == "__main__":
    sys.exit(main())
