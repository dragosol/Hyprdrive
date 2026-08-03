#!/usr/bin/env python3
"""X29 dock frost, host-side. Recovers the blur's SIGMA and BRIGHTNESS from the
pixels rather than trusting the config, because Hyprland has no sigma at all --
it has dual-kawase size/passes, and what those two mean in blur-my-shell's units
is exactly the question the spec asks.

nodock.png is the same wallpaper with nothing running, i.e. the un-blurred
backdrop the pill samples. For a candidate sigma the model is

    out = (1 - A) * brightness * gaussian(backdrop, sigma) + A * tint

with A and tint the pill's own background (D2D background-opacity 0.19 over
rgb(192,191,188)). brightness is solved per sigma by least squares, so the search
is one-dimensional.

Reference: blur-my-shell [dash-to-dock] sigma 30, brightness 0.60.
"""
import sys

import numpy as np
from PIL import Image, ImageFilter

SIGMA_REF, BRIGHT_REF = 30.0, 0.60
TINT_A, TINT_RGB = 0.19, np.array([192.0, 191.0, 188.0])
SIGMA_TOL, BRIGHT_TOL = 6.0, 0.08
# Inside the pill, clear of its rounded corners and of the icon row. The corner
# radius is 24, so the horizontal inset has to clear that and no more -- a wider
# one empties the band entirely on a one-icon pill.
INSET_X, INSET_Y = 26, 4


def pill_box(dock, nodock):
    """The pill is what differs between the two frames -- inside the bottom band.
    Unconstrained, this also caught the fixture windows repainting between the
    two shots and returned a 487x1066 'pill'."""
    d = np.asarray(dock.convert("RGB")).astype(int)
    n = np.asarray(nodock.convert("RGB")).astype(int)
    top = d.shape[0] - 160
    ys, xs = np.where(np.abs(d[top:] - n[top:]).sum(2) > 20)
    return xs.min(), ys.min() + top, xs.max(), ys.max() + top


def fit(dock_png, nodock_png, sigmas):
    """Returns (sigma, brightness, rmse, offset) for one pair of frames."""
    global x0, y0, x1, y1
    dock = Image.open(dock_png).convert("RGB")
    nodock = Image.open(nodock_png).convert("RGB")
    x0, y0, x1, y1 = pill_box(dock, nodock)

    def bands(img):
        a = np.asarray(img).astype(float)
        xs = slice(x0 + INSET_X, x1 - INSET_X)
        return np.concatenate([a[y0 + INSET_Y:y0 + 11, xs].ravel(),
                               a[y1 - 10:y1 - INSET_Y, xs].ravel()])

    target = bands(dock)
    if target.size == 0:
        sys.exit("ABORT: the sample band is empty -- the pill is narrower than 2*INSET_X")

    best = None
    for s in sigmas:
        ref = bands(nodock.filter(ImageFilter.GaussianBlur(s)))
        A = np.stack([ref, np.ones_like(ref)], 1)
        (a, c), *_ = np.linalg.lstsq(A, target, rcond=None)
        e = float(np.sqrt(((A @ [a, c] - target) ** 2).mean()))
        if best is None or e < best[2]:
            best = (float(s), float(a) / (1 - TINT_A), e, float(c))
    return best


SIGMAS = np.arange(2.0, 140.0, 0.5)

sigma, bright, err, offset = fit("dock.png", "nodock.png", SIGMAS)
print(f"desktop  pill {x1 - x0 + 1}x{y1 - y0 + 1}  sigma {sigma:.1f}  brightness {bright:.3f}  "
      f"rmse {err:.2f}/255  offset {offset:.1f} (tint alone would be {TINT_A * TINT_RGB.mean():.1f})")

# The overview's backdrop under the pill is itself blurred and nearly flat, so
# re-FITTING there is degenerate -- scale and offset cannot be separated when the
# reference is a constant, and it duly returned brightness 0.796 with an rmse of
# 0.32, i.e. an excellent fit to a meaningless pair of numbers. So the overview is
# PREDICTED from the desktop calibration instead, which has no free parameters:
# unblurred backdrop -> what a frosted pill over it must read.
ov_dock = np.asarray(Image.open("dock_ov.png").convert("RGB")).astype(float)
ov_back = np.asarray(Image.open("nodock_ov.png").convert("RGB").filter(ImageFilter.GaussianBlur(sigma))).astype(float)
rows, cols = slice(y0 + INSET_Y, y0 + 11), slice(x0 + INSET_X, x1 - INSET_X)
ov_seen = float(ov_dock[rows, cols].mean())
ov_want = float((1 - TINT_A) * bright * ov_back[rows, cols].mean() + TINT_A * TINT_RGB.mean())
# A pill with no frost at all is the same tint over the raw backdrop.
ov_bare = float((1 - TINT_A) * np.asarray(Image.open("nodock_ov.png").convert("RGB")).astype(float)[rows, cols].mean() + TINT_A * TINT_RGB.mean())
print(f"overview pill mean {ov_seen:.1f}   frosted predicts {ov_want:.1f}   unfrosted would be {ov_bare:.1f}")

ok = True
for name, cond, detail in [
    ("P1 blur sigma matches blur-my-shell's 30",
     abs(sigma - SIGMA_REF) <= SIGMA_TOL, f"measured {sigma:.1f}, want {SIGMA_REF} +-{SIGMA_TOL}"),
    ("P2 blur brightness matches blur-my-shell's 0.60",
     abs(bright - BRIGHT_REF) <= BRIGHT_TOL, f"measured {bright:.3f}, want {BRIGHT_REF} +-{BRIGHT_TOL}"),
    ("P3 the model actually fits, so P1/P2 mean something",
     err < 3.0, f"rmse {err:.2f}/255, offset {offset:.1f} vs tint {TINT_A * TINT_RGB.mean():.1f}"),
    ("P4 the dock keeps its frost in the overview (unblur-in-overview=false)",
     abs(ov_seen - ov_want) < 6.0 and abs(ov_seen - ov_want) < abs(ov_seen - ov_bare),
     f"seen {ov_seen:.1f}, frosted predicts {ov_want:.1f}, unfrosted {ov_bare:.1f}"),
]:
    print(("PASS " if cond else "FAIL ") + name + "  " + detail)
    ok &= bool(cond)

sys.exit(0 if ok else 1)
