#!/usr/bin/env python3
"""X47 FROST gate. Runs on the HOST against /home/dragos/hyprvm/share/x47.

OVERVIEW_CPP_SPEC 13.12 X47 says the hover panel is "frosted blur per section
C". x47_gate.py grades six claims and NONE of them is that one, so X47 shipped
with its frost asserted and never measured.

WHY AN A/B AND NOT A THRESHOLD. A single frosted screenshot cannot be graded:
"is this blurred" needs something to be blurred *relative to*, and the standing
rule in this tree is that frost is proven by pixel variance and never by eye. So
the rig is run twice over an IDENTICAL fixture, changing nothing but the panel's
own runtime blur keys (Dock.cpp:2628, read per frame):

    sharp arm    blur_size=1,  blur_passes=1
    frosted arm  blur_size=20, blur_passes=4

The backdrop is then bit-identical between the arms -- SAMEBACK asserts it -- so
every difference inside the plate is caused by the blur pass and nothing else.
No rebuild is needed, which is what makes this cheap enough to keep in the suite.

WHY THREE CHECKS AND NOT ONE. Each alone has a way to pass on a broken build:

  * BLURS alone (high frequency drops) is also true of a plate that stopped
    drawing the backdrop at all and went opaque -- flat is the smoothest thing
    there is.
  * BACKDROP alone (the plate tracks what is behind it) is also true of a plate
    with no blur whatsoever: a clear pane tracks its backdrop perfectly.
  * RADIUS alone (the two arms differ) is true of any config-dependent tint.

Together they pin it: the plate shows the backdrop, smeared, and the amount of
smearing follows the blur radius.

AND THE MEASUREMENT IS ON THE AXIS THE FIXTURE VARIES ON. The X47_STRIPES
fixture paints HORIZONTAL stripes, so its structure lives along y. Graded along
x instead -- the first way this was written -- the raw backdrop scores LOWER
than the blurred plate (0.68 vs 1.83) and the check reads exactly like a product
failure. TEXTURE asserts the structure exists on the measured axis before
anything is believed, which is the same hole that let a blank capture set score
2 of 6 green in x47_gate.py.

usage: x47_frost.py <sharp-tag> <frosted-tag>
"""
import sys
import pathlib
import numpy as np
from PIL import Image

DIR = pathlib.Path("/home/dragos/hyprvm/share/x47")
SHARP = sys.argv[1] if len(sys.argv) > 2 else "fa"
FROST = sys.argv[2] if len(sys.argv) > 2 else "fb"

# Dock.cpp:150-153. Scale is 1 on the rig's 2560x1600 headless output.
PAD, GAP = 10, 10


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
    is fatal here: a region shifted 190px is half off the plate, and the first
    version of this gate read HF 7.35 -> 6.40 and FAILED a build that measures
    3.26 -> 1.45 on the plate's real pixels.
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
NCELL = 3
AVAIL = PW - 2 * PAD - (NCELL - 1) * GAP
CW = AVAIL / float(NCELL)
BG = np.ones((PH, PW), bool)
for i in range(NCELL):
    x0 = int(round(PAD + i * (CW + GAP)))
    BG[PAD:PH - PAD, x0:int(round(x0 + CW))] = False

results = []


def check(name, ok, detail):
    results.append((name, ok, detail))
    print("%-9s %s  %s" % (name, "PASS" if ok else "FAIL", detail))


def hf_y(img):
    """Mean vertical gradient over the plate background -- the axis the stripe
    fixture varies on. Blur is exactly the thing that makes this smaller."""
    g = img.mean(axis=2)
    dy = np.abs(np.diff(g, axis=0))
    m = BG[1:] & BG[:-1]
    return dy[m].mean()


def row_profile(img):
    """Mean luminance per row over the background pixels of that row. A 1-D
    signature of what the plate is showing, comparable against the backdrop."""
    g = img.mean(axis=2)
    out = np.full(PH, np.nan)
    for r in range(PH):
        v = g[r][BG[r]]
        if v.size > 4:
            out[r] = v.mean()
    return out


hf_back, hf_sharp, hf_frost = hf_y(sharp_c), hf_y(sharp_h), hf_y(frost_h)

# --- TEXTURE. Graded first. A blur over a FLAT backdrop is a no-op, so on the
# --- rig's original blank fixture every check below is true of nothing: the
# --- band's two control frames were byte-identical, measured. X47_STRIPES=1
# --- exists to put structure here and this asserts it arrived.
check("TEXTURE", hf_back > 2.0 and sharp_c.mean(axis=2)[BG].std() > 20.0,
      "backdrop behind the plate: HF-y %.2f, luminance sd %.1f (needs >2.0, >20)"
      % (hf_back, sharp_c.mean(axis=2)[BG].std()))

# --- SAMEBACK. The whole A/B rests on the two arms seeing the same thing. ----
delta_c = np.abs(sharp_c - frost_c).max()
check("SAMEBACK", delta_c <= 2.0,
      "control frames of the two arms differ by at most %.1f/255 over the plate rect" % delta_c)

# --- BLURS ------------------------------------------------------------------
check("BLURS", hf_sharp > 1.0 and hf_frost < 0.6 * hf_sharp,
      "plate-background HF-y %.2f sharp -> %.2f frosted (%.1fx suppression)"
      % (hf_sharp, hf_frost, hf_sharp / max(hf_frost, 0.01)))

# --- BACKDROP: the plate SHOWS what is behind it, so it is not an opaque fill.
pc, ps, pf = row_profile(sharp_c), row_profile(sharp_h), row_profile(frost_h)
ok = ~np.isnan(pc) & ~np.isnan(ps) & ~np.isnan(pf)
r_sharp = np.corrcoef(ps[ok], pc[ok])[0, 1]
r_frost = np.corrcoef(pf[ok], pc[ok])[0, 1]
check("BACKDROP", r_sharp > 0.7 and r_frost > 0.25,
      "row-profile correlation with the backdrop: %.3f sharp, %.3f frosted (%d rows)"
      % (r_sharp, r_frost, ok.sum()))

# --- RADIUS: the blur KEYS reach the render. Without this the two arms could
# --- agree and still be frosted -- by a hardcoded radius nobody can tune.
d = np.abs(sharp_h - frost_h).max(axis=2)
moved = (d[BG] > 8).sum()
check("RADIUS", d[BG].mean() > 10.0 and moved > 0.5 * BG.sum(),
      "%d of %d plate-background px moved >8/255 between the arms, mean |delta| %.1f"
      % (moved, BG.sum(), d[BG].mean()))

bad = [n for n, ok, _ in results if not ok]
print()
print("X47 FROST GATE: %s" % ("PASS" if not bad else "FAIL (%s)" % ", ".join(bad)))
sys.exit(1 if bad else 0)
