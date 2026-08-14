#!/usr/bin/env python3
"""X47 FROST gate. Runs against /home/dragos/hyprvm/share/x47.

OVERVIEW_CPP_SPEC 13.12 X47 says the hover panel is "frosted blur per section
C". x47_gate.py grades six claims and NONE of them is that one, so X47 shipped
with its frost asserted and never measured.

WHY AN A/B AND NOT A THRESHOLD. A single frosted screenshot cannot be graded:
"is this blurred" needs something to be blurred *relative to*, and the standing
rule in this tree is that frost is proven by pixel variance and never by eye. So
the rig is run twice over an IDENTICAL fixture, changing nothing but the panel's
own runtime blur keys (Dock.cpp, read per frame):

    sharp arm    blur_size=1,  blur_passes=1
    frosted arm  blur_size=20, blur_passes=4

The backdrop is then bit-identical between the arms -- SAMEBACK asserts it -- so
every difference inside the plate is caused by the blur pass and nothing else.
No rebuild is needed, which is what makes this cheap enough to keep in the suite.

WHERE THE MEASUREMENT IS TAKEN, and this is the whole story of three rounds of
red. The plate is 634x152 with three preview cells inset by PAD=10 and split by
GAP=10, so the only plate BACKGROUND in it is a 10px ring plus two 10px gaps.
Every earlier version of this file averaged over that whole set, which for 594
of the 634 columns is *the ten rows above and below the cells and nothing else*.
Measured on the 2026-08-14 suite frames: the "column-profile sd 28.32" that
TEXTURE was passing on was not picture structure at all, it was the mask -- 594
columns averaging 20 border pixels against 40 columns averaging 152. And HF-y,
which BLURS graded, was reading the plate's own rounded edge, which no blur
setting moves: 3.68 sharp -> 3.47 frosted, a "1.1x suppression" that was really
"the border is the border in both arms".

So the measurement is taken on the columns that are background for their WHOLE
height -- the two sides of the ring and the two cell gaps, 34 of them after a
3px inset off the plate's anti-aliased edge -- and it is taken along Y, which is
the axis this backdrop actually varies on. What is behind the plate is the
compositor's own background (quickshell paints no wallpaper on the HEADLESS
output these arms run on): flat, with ONE hard horizontal step, measured at
219.8 -> 3.4 seventeen rows down. That step is the structure, and a frost is a
claim about exactly two things happening to it.

THE TWO SCALES, which is the pattern x64's frost check was regraded to in round
B, applied here to a step instead of to picture detail:

  FINE DETAIL GONE   the step is no longer resolvable. Graded as EDGEFRAC: how
                     much of the profile's own dynamic range falls across the
                     five rows around the step. Sharp 0.921, frosted 0.023.
                     It is a RATIO on purpose -- a plate that merely dimmed the
                     backdrop instead of blurring it scores identically to the
                     sharp arm (measured: a synthetic 0.5x tint scores 0.921),
                     so contrast alone cannot buy a pass.
  COARSE SHAPE REMAINS  the frosted plate still tracks bright-above-dark-below.
                     Graded as the correlation of the row profiles: sharp 0.990,
                     frosted 0.479, and a plate that went opaque has no profile
                     to correlate at all.

Neither alone is enough and that is why there are two: an opaque plate is the
smoothest thing there is and would sail through the first, while an unblurred
one tracks the backdrop perfectly and would sail through the second. SELFTEST
below builds both of those out of the run's own frames, plus a dim-instead-of-
blur and a no-plate-at-all, and fails the gate if the criteria above would let
any of them through. A gate that cannot say what it rejects is not a gate.

usage: x47_frost.py <sharp-tag> <frosted-tag>
"""
import sys
import pathlib
import numpy as np
from PIL import Image

DIR = pathlib.Path("/home/dragos/hyprvm/share/x47")
SHARP = sys.argv[1] if len(sys.argv) > 2 else "fa"
FROST = sys.argv[2] if len(sys.argv) > 2 else "fb"

# Dock.cpp's renderHoverPreview layout. Scale is 1 on the rig's 2560x1600
# headless output. INSET keeps the plate's own anti-aliased edge and border
# stroke out of the sample: those are chrome, they are identical in both arms,
# and letting them in is what made the old BLURS number meaningless.
PAD, GAP, NCELL, INSET = 10, 10, 3, 3


def band(tag, name):
    p = DIR / ("%s-%s.png" % (tag, name))
    if not p.exists():
        sys.exit("MISSING FRAME: %s" % p)
    return np.asarray(Image.open(p).convert("RGB")).astype(float)


def plate_rect(tag):
    """The panel in BAND coords, MEASURED.

    Deliberately not the x out of `<tag>-panel.txt`. That file's width and y are
    exact and its x is not: on run `fa` it predicts 1134 while the plate is at
    944, which is `icon_x - width/2` -- the panel is centred on the icon it rose
    from. The error is latent in x47_gate.py, which reads py and never px, and it
    is fatal here: a region shifted 190px is half off the plate.
    """
    _, py, pw, ph = [int(v) for v in (DIR / ("%s-panel.txt" % tag)).read_text().split()]
    h = np.asarray(Image.open(DIR / ("%s-h0.png" % tag)).convert("RGB")).astype(float)
    c = np.asarray(Image.open(DIR / ("%s-c0.png" % tag)).convert("RGB")).astype(float)
    rows = slice(24, 24 + ph)
    col = (np.abs(h[rows] - c[rows]).max(axis=2) > 18).sum(axis=0)
    on = np.where(col > 0.3 * ph)[0]
    if on.size == 0:
        sys.exit("NO PLATE: nothing in the band changed when the icon was hovered (%s)" % tag)
    x0, x1 = on.min(), on.max() + 1
    if abs((x1 - x0) - pw) > 24:
        sys.exit("PLATE WIDTH %d, expected %d (%s)" % (x1 - x0, pw, tag))
    return int(x0), 24, pw, ph


PX, PY, PW, PH = plate_rect(SHARP)
print("plate measured at band x=%d (w=%d h=%d)" % (PX, PW, PH))
SL = (slice(PY, PY + PH), slice(PX, PX + PW))

sharp_h, frost_h = band(SHARP, "h0")[SL], band(FROST, "h0")[SL]
sharp_c, frost_c = band(SHARP, "c0")[SL], band(FROST, "c0")[SL]

# The frost is what shows BETWEEN and AROUND the preview cells -- the cells are
# opaque window textures and say nothing about the plate behind them. Cell boxes
# come from renderHoverPreview()'s own layout: PAD inset, GAP between, the width
# split by preview aspect (equal here, the fixture's windows are all tiled the
# same). One cell per X47A window, three of them.
AVAIL = PW - 2 * PAD - (NCELL - 1) * GAP
CW = AVAIL / float(NCELL)
BG = np.ones((PH, PW), bool)
for i in range(NCELL):
    x0 = int(round(PAD + i * (CW + GAP)))
    BG[PAD:PH - PAD, x0:int(round(x0 + CW))] = False
BG[:INSET, :] = BG[PH - INSET:, :] = False
BG[:, :INSET] = BG[:, PW - INSET:] = False

# Background for their WHOLE height. See the header: averaging a column that is
# background for twenty rows against one that is background for all of them
# measures the mask, not the picture.
ROWS = slice(INSET, PH - INSET)
COLS = BG.sum(axis=0) >= (PH - 2 * INSET)
if COLS.sum() < 12:
    sys.exit("NO BACKGROUND COLUMNS: %d full-height background columns in a %dx%d plate -- "
             "the cell layout assumed here (PAD %d, GAP %d, %d cells) does not match what was drawn"
             % (COLS.sum(), PW, PH, PAD, GAP, NCELL))

results = []


def check(name, ok, detail):
    results.append((name, ok, detail))
    print("%-9s %s  %s" % (name, "PASS" if ok else "FAIL", detail))


def profile(img):
    """Mean luminance per row over the full-height background columns. The 1-D
    signature of what the plate is showing, on the axis the backdrop varies on."""
    return img.mean(axis=2)[ROWS][:, COLS].mean(axis=1)


def edgefrac(p, e):
    """How much of this profile's own dynamic range falls across the five rows
    around row `e`. Scale-invariant by construction: dimming the plate divides
    both the rise and the range by the same number."""
    rise = abs(p[max(0, e - 2)] - p[min(len(p) - 1, e + 3)])
    rng = float(p.max() - p.min())
    return rise, rng, rise / max(rng, 1e-6)


def correlate(p, ref):
    if p.std() < 1e-9 or ref.std() < 1e-9:
        return float("nan")  # a flat plate has no shape to compare
    return float(np.corrcoef(p, ref)[0, 1])


BACK = profile(sharp_c)
EDGE = int(np.argmax(np.abs(np.diff(BACK))))
STEP = float(np.abs(np.diff(BACK))[EDGE])

# --- TEXTURE. Graded first, and it is a precondition on the SCENE, not on the
# --- plate: a blur over a flat backdrop is a no-op, and on the rig's original
# --- blank fixture every check below was true of nothing. The step has to be
# --- inside the plate with room on both sides for the five-row window and for a
# --- blurred ramp to be visibly wider than it.
check("TEXTURE", STEP > 40.0 and 6 <= EDGE <= len(BACK) - 8 and float(BACK.std()) > 15.0,
      "backdrop over the %d full-height background columns: step %.1f/255 at row %d of %d, profile sd %.1f "
      "(needs >40, 6..%d, >15)" % (COLS.sum(), STEP, EDGE, len(BACK), BACK.std(), len(BACK) - 8))

# --- SAMEBACK. The whole A/B rests on the two arms seeing the same thing. ----
delta_c = float(np.abs(sharp_c - frost_c).max())
check("SAMEBACK", delta_c <= 2.0,
      "control frames of the two arms differ by at most %.1f/255 over the plate rect" % delta_c)

SHARPP, FROSTP = profile(sharp_h), profile(frost_h)
s_rise, s_rng, s_frac = edgefrac(SHARPP, EDGE)
f_rise, f_rng, f_frac = edgefrac(FROSTP, EDGE)

# --- BLURS: the fine detail is GONE. Two conditions, because a blur does two
# --- things to a step and a cheat can only fake one: it stops resolving the
# --- edge (the ratio), and it compresses what the plate shows into a narrower
# --- range than the sharp arm does (the range). A synthetic plate that keeps
# --- the sharp pixels behind a 6px translucent border passes the first and
# --- fails the second; SELFTEST holds both.
check("BLURS", s_frac > 0.5 and f_frac < 0.25 * s_frac and f_rng < 0.6 * s_rng,
      "step across the plate: EDGEFRAC %.3f sharp -> %.3f frosted, profile range %.1f -> %.1f"
      % (s_frac, f_frac, s_rng, f_rng))

# --- BACKDROP: the plate SHOWS what is behind it, so it is not an opaque fill.
r_sharp, r_frost = correlate(SHARPP, BACK), correlate(FROSTP, BACK)
check("BACKDROP", r_sharp > 0.9 and r_frost > 0.35,
      "row-profile correlation with the backdrop: %.3f sharp, %.3f frosted (%d rows)"
      % (r_sharp, r_frost, len(BACK)))

# --- RADIUS: the blur KEYS reach the render. Without this the two arms could
# --- agree and still be frosted -- by a hardcoded radius nobody can tune.
d = np.abs(sharp_h - frost_h).max(axis=2)
moved = int((d[BG] > 8).sum())
check("RADIUS", d[BG].mean() > 10.0 and moved > 0.5 * BG.sum(),
      "%d of %d plate-background px moved >8/255 between the arms, mean |delta| %.1f"
      % (moved, BG.sum(), d[BG].mean()))


# --- SELFTEST. The criteria above, run against frosted arms this gate must
# --- reject, built out of this very run's frames so they are not a fixture that
# --- can rot. A pass that cannot name what it rejects is a pass by luck.
def verdict(frosted):
    """BLURS and BACKDROP as applied to a candidate frosted plate."""
    p = profile(frosted)
    _, rng, frac = edgefrac(p, EDGE)
    r = correlate(p, BACK)
    blurs = s_frac > 0.5 and frac < 0.25 * s_frac and rng < 0.6 * s_rng
    backdrop = r_sharp > 0.9 and (r > 0.35)  # nan > 0.35 is False, which is the point
    return blurs and backdrop, frac, rng, r


FLAT = float(sharp_h.mean(axis=2)[BG].mean())
opaque = np.full_like(sharp_h, FLAT)
ringed = sharp_h.copy()
ringed[6:PH - 6, 6:PW - 6] = FLAT

MUTANTS = [
    ("UNBLURRED", sharp_h, "the frosted arm did not blur at all"),
    ("CLEARPANE", sharp_c, "no plate drawn -- the backdrop showing through"),
    ("DIMMED", sharp_h * 0.5, "dimmed instead of blurred, contrast halved"),
    ("OPAQUE", opaque, "the plate stopped showing its backdrop and went flat"),
    ("OPAQUERING", ringed, "opaque but for a 6px translucent border"),
]
selftest_bad = []
print()
for name, img, why in MUTANTS:
    passed, frac, rng, r = verdict(img)
    print("SELFTEST  %-11s %-8s EDGEFRAC %.3f range %6.1f corr %s   (%s)"
          % (name, "ADMITTED" if passed else "rejected", frac, rng, ("%.3f" % r) if r == r else "  n/a", why))
    if passed:
        selftest_bad.append(name)

check("SELFTEST", not selftest_bad,
      "%d synthetic frosted arms offered, %d admitted%s"
      % (len(MUTANTS), len(selftest_bad), (" (" + ", ".join(selftest_bad) + ")") if selftest_bad else ""))

bad = [n for n, ok, _ in results if not ok]
print()
print("X47 FROST GATE: %s" % ("PASS" if not bad else "FAIL (%s)" % ", ".join(bad)))
sys.exit(1 if bad else 0)
