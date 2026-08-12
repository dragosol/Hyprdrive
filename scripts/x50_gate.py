#!/usr/bin/env python3
# Grades the X50 rig on the HOST (the guest has no numpy/PIL).
#
# Everything is measured as CHANGED PIXELS PER ROW inside the central column
# band the pill lives in, against the resting frame a1. The pill is ~430
# logical px wide and centred, so +-260px around the centre sees the pill and
# little else; the result cards are half the monitor wide and sit lower.
#
# The band that decides it is SELF-CALIBRATED and deliberately narrow:
#   floor  the bottom edge of the layer-shell bar (from layers.json, NOT from
#          `reserved` -- this bar reserves nothing), plus the dock pad.
#   roof   the resting pill's own top edge, taken from the NOMATCH frame: a
#          keystroke widens the pill in place, so the topmost row that changes
#          there IS where the pill rests.
# Nothing may be in that strip unless the pill travelled into it, and the
# docked pill is 48 logical px tall so it must reach well into it.
import json, pathlib, sys
import numpy as np
from PIL import Image

OUT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/home/dragos/hyprvm/share/x50")
TAG = sys.argv[2] if len(sys.argv) > 2 else "r1"

mons = json.loads((OUT / "monitors.json").read_text())
mon = next(m for m in mons if m["name"].startswith("HEADLESS"))
W, H = mon["width"], mon["height"]
CX = W // 2
COL0, COL1 = max(0, CX - 260), min(W, CX + 260)

layers = json.loads((OUT / "layers.json").read_text())
BAR = 0
for name, v in layers.items():
    if not name.startswith("HEADLESS"):
        continue
    for lvl, surfaces in v["levels"].items():
        if lvl not in ("2", "3"):  # TOP, OVERLAY
            continue
        for s in surfaces:
            if s["w"] >= W * 0.5 and s["h"] <= H / 3:
                BAR = max(BAR, s["h"])


def load(name):
    return np.asarray(Image.open(OUT / f"{TAG}-{name}.png").convert("RGB"), dtype=np.int16)


# How different a pixel has to be to count. 24 was too coarse to see the thing
# this gate is about: the search pill is a FROSTED plate over the overview's own
# backdrop, and on this theme its body sits 4-8 units away from what is behind
# it -- only the magnifier glyph and the query text clear 24. Measured
# 2026-08-12 over the docked frame's own band:
#     thresh   4      6      8     12     24
#     dock  12710   7796   2737    923    899     <- the pill, travelled
#     drift    54     54     53     53     50     <- the resting control
#     nomatch   0      0      0      0      0
#     clear     0      0      0      0      0
# 6 is where the pill is fully visible and the controls have not moved at all;
# 24 read the same travel as 899px and called it "it did not travel".
DELTA = 6


def rowprofile(a, b):
    d = np.abs(a - b).max(axis=2)[:, COL0:COL1]
    return (d > DELTA).sum(axis=1)


a0, a1 = load("00-a0"), load("01-a1")
dock, clear, nomatch = load("10-dock"), load("20-clear"), load("30-nomatch")

fails = []

# Control 1: the resting output is not drifting, so a later diff means something.
drift = int(rowprofile(a0, a1).sum())
print(f"CONTROL rest drift a0 vs a1: {drift} changed px")
if drift > 2000:
    fails.append(f"resting output drifts ({drift} px) -- no later diff is trustworthy")

# Control 2: the NOMATCH keystroke landed at all. It widens the pill in place,
# so this both proves input worked AND locates the resting pill.
#
# Searched BELOW THE BAR, and that is not a detail. The quickshell bar is a
# layer surface across the top of this output and its clock and CPU readouts
# tick on their own, so the topmost changed row over the whole frame is a bar
# pixel whenever a readout moved between the two captures. Measured 2026-08-12:
# REST_TOP came back as 7 -- inside a 63px bar -- and the strip the gate then
# graded was "67..3", an inverted range, which it reported as "the pill rests on
# the bar already" and blamed on the build.
pno = rowprofile(a1, nomatch)
rows = np.nonzero(pno > 8)[0]
rows = rows[rows >= BAR + 4]
if rows.size == 0:
    print("FAIL: the nomatch keystroke changed nothing below the bar -- input did not land")
    sys.exit(1)
REST_TOP = int(rows[0])
TOP0, TOP1 = BAR + 4, REST_TOP - 4
print(f"monitor {W}x{H}  bar {BAR}px  resting pill top {REST_TOP}  cols {COL0}..{COL1}  strip {TOP0}..{TOP1}")
if TOP1 - TOP0 < 12:
    fails.append(f"strip {TOP0}..{TOP1} is too thin to judge -- the pill rests on the bar already")

for name, frame in (("dock", dock), ("nomatch", nomatch), ("clear", clear)):
    prof = rowprofile(a1, frame)
    strip = int(prof[TOP0:TOP1].sum())
    total = int(prof.sum())
    r = np.nonzero(prof > 8)[0]
    print(f"{name:8s} total {total:7d}   IN STRIP {strip:6d}   topmost changed row {int(r[0]) if r.size else -1}")

sdock = int(rowprofile(a1, dock)[TOP0:TOP1].sum())
sno = int(rowprofile(a1, nomatch)[TOP0:TOP1].sum())
sclear = int(rowprofile(a1, clear)[TOP0:TOP1].sum())

if sdock < 3000:
    fails.append(f"DOCK: only {sdock} px changed between the bar and the resting pill -- it did not travel")
if sno > max(500, sdock * 0.15):
    fails.append(f"NOMATCH: {sno} px in the strip vs {sdock} docked -- it moved on the keystroke, not on results")
if sclear > max(500, sdock * 0.15):
    fails.append(f"CLEAR: {sclear} px still in the strip vs {sdock} docked -- it did not come back")

print()
if fails:
    for f in fails:
        print("FAIL:", f)
    sys.exit(1)
print("X50 PASS: the pill travels into the band under the bar when results populate, "
      "stays put when nothing matches, and returns on clear")
