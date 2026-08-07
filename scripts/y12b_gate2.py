#!/usr/bin/env python3
"""Y12(b): compare the dock's frost against a window's as an ATTENUATION CURVE.

The first cut used two frequencies and could not read the finer one: a
dual-kawase at these radii kills a 10px period stone dead under BOTH plates, so
both measured essentially zero and the comparison was noise against noise. And
the "noise floor" it took from the coarse half was not noise at all -- a square
wave's edges are broadband, so a 41px moving average leaves plenty of
high-frequency residue behind.

So: FOUR zones across the screen, each a square wave of its own period, and the
amplitude at each period read from an FFT bin rather than from a broadband std.
An FFT bin ignores the other zones' edges by construction, and the bins either
side of the peak give a real noise floor.

  zone 0   ~10px period    killed by any of these blurs -- a sanity check
  zone 1   ~30px period    partially attenuated: THIS is where radius shows
  zone 2   ~80px period    lightly attenuated
  zone 3  ~160px period    almost untouched: this is essentially pure TINT

Both plates straddle zones 1 and 2 by construction (the test window is placed at
x 640..1920 and the pill is centred), so those are the two that get compared.

A blur difference bends the curve. A tint difference moves it up or down as a
whole. Reading all four is what tells those apart without having to trust either
plate's configured opacity.

usage: y12b_gate2.py <dir> <tag> <desktop|overview>
"""
import sys

import numpy as np
from PIL import Image


def profile(img, y0, y1, x0, x1):
    return img[y0:y1, x0:x1].astype(np.float64).mean(axis=2).mean(axis=0)


def peak_amp(p):
    """Amplitude of the dominant periodic component, and the local noise floor.

    Detrended and windowed first: a plate's own gradient is a huge DC-adjacent
    term that would otherwise swamp the bin being looked for.
    """
    n = len(p)
    if n < 64:
        return 0.0, 1.0, 0.0
    x = np.arange(n)
    p = p - np.polyval(np.polyfit(x, p, 1), x)
    p = p * np.hanning(n)
    mag = np.abs(np.fft.rfft(p)) / (n / 4.0)
    lo = max(3, int(n / 400))          # ignore DC and anything slower than the zone
    band = mag[lo:len(mag) // 2]
    if not len(band):
        return 0.0, 1.0, 0.0
    k = int(np.argmax(band)) + lo
    amp = float(mag[k])
    # floor: the median of the bins well away from the peak
    mask = np.ones(len(mag), bool)
    mask[: lo] = False
    mask[max(0, k - 3): k + 4] = False
    floor = float(np.median(mag[mask])) if mask.any() else 0.0
    return amp, max(floor, 1e-6), n / k


def main():
    d, tag, which = sys.argv[1], sys.argv[2], sys.argv[3]
    img = np.asarray(Image.open("%s/%s-%s.png" % (d, tag, which)).convert("RGB"))
    h, w = img.shape[:2]
    tx, ty, tw, th = [int(v) for v in open("%s/%s-win.txt" % (d, tag)).read().split()]
    q = w // 4

    # The pill: the plate's own top rows. Its box comes from the frost detector
    # in y12b_gate.py, imported rather than duplicated.
    sys.path.insert(0, __file__.rsplit("/", 1)[0])
    from y12b_gate import find_pill  # noqa: E402

    pill = find_pill(img, w // 2)
    if pill is None:
        print("ABORT: could not find the pill")
        return 2
    px0, px1, py0, py1 = pill
    print("pill x %d..%d y %d..%d   window x %d..%d y %d..%d" % (px0, px1, py0, py1, tx, tx + tw, ty, ty + th))

    rows = {
        "backdrop": (200, 300),
        "window": (ty + 40, ty + th - 40),
        "pill": (py0 + 4, min(py0 + 18, py1)),
    }

    print("\n%-9s %-8s %10s %10s %8s" % ("surface", "zone", "amp", "floor", "period"))
    amp = {}
    for name, (y0, y1) in rows.items():
        for z in range(4):
            zx0, zx1 = z * q, (z + 1) * q
            if name != "backdrop":
                sx0 = max(zx0, px0 + 20 if name == "pill" else tx + 30)
                sx1 = min(zx1, px1 - 20 if name == "pill" else tx + tw - 30)
            else:
                sx0, sx1 = zx0 + 20, zx1 - 20
            if sx1 - sx0 < 120:
                continue
            a, f, per = peak_amp(profile(img, y0, y1, sx0, sx1))
            amp[(name, z)] = (a, f, per)
            print("%-9s zone %d   %10.3f %10.3f %8.1f px" % (name, z, a, f, per))

    print("\n%-6s %12s %12s %12s" % ("zone", "kept:window", "kept:pill", "pill/window"))
    shared = []
    for z in range(4):
        if ("backdrop", z) not in amp or ("window", z) not in amp or ("pill", z) not in amp:
            continue
        b = amp[("backdrop", z)][0]
        if b < 5:
            continue
        wk = amp[("window", z)][0] / b
        pk = amp[("pill", z)][0] / b
        # only trust a zone where at least one plate is above its own floor
        trusted = amp[("window", z)][0] > 3 * amp[("window", z)][1] or amp[("pill", z)][0] > 3 * amp[("pill", z)][1]
        print("zone %d %11.4f %12.4f %12.2f %s" % (z, wk, pk, pk / max(wk, 1e-9), "" if trusted else "(below floor)"))
        if trusted:
            shared.append((z, wk, pk))

    if len(shared) < 2:
        print("\nINCONCLUSIVE: fewer than two zones survive both plates above the noise floor.")
        return 2

    ratios = [pk / max(wk, 1e-9) for _, wk, pk in shared]
    spread = max(ratios) / max(min(ratios), 1e-9)
    print("\npill/window across the trusted zones: %s" % ["%.2f" % r for r in ratios])
    print("spread %.2f  (1.0 = the same curve shifted, i.e. TINT only)" % spread)

    if spread < 1.25 and 0.85 < np.mean(ratios) < 1.18:
        print("\nY12(b) PASS -- same attenuation at every frequency: the same frost")
        return 0
    if spread < 1.25:
        print("\nY12(b) FAIL: the CURVES ARE PARALLEL, so the blur radius matches and")
        print("the difference is a flat factor of %.2f -- TINT. That is 7afcf63's" % float(np.mean(ratios)))
        print("written hypothesis, now measured.")
        return 1
    print("\nY12(b) FAIL: the curves are NOT parallel (spread %.2f), so the two plates" % spread)
    print("blur at different radii -- this is not a tint difference alone.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
