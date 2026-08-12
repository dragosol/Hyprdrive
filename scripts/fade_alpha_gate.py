#!/usr/bin/env python3
# Grades the chrome-fade ALPHA gate on the HOST.
#
# WHY THIS SHAPE AND NOT A FILM OF THE ANIMATION. The overview's open resolves
# in ~3 frames of a 60fps capture in this guest, and the plugin's speed knobs
# cannot be turned down for the camera (0.56's Lua parser rejects the plugin's
# Hyprlang keys: "unknown config key 'plugin.hyprdrive.open_speed'"). A
# 3-frame transition cannot be phase-matched across two builds, so filming it
# proves nothing either way. What CAN be pinned is the fade factor itself:
# build once with FADE forced to 0.5, capture the SETTLED overview, and compare
# against the same settled overview at FADE=1. Same geometry, same fixture,
# same wallpaper -- the only variable left is alpha.
#
# Do NOT measure "difference from the desktop frame": the overview draws a dark
# backdrop over the wallpaper, so the thing behind the chrome is not the
# desktop and that metric moves the wrong way. Measure the chrome against the
# BACKDROP BESIDE IT.
#
# Usage: fade_alpha_gate.py <full-settled.png> <half-settled.png>
import sys
import numpy as np
from PIL import Image

full = np.asarray(Image.open(sys.argv[1]).convert("RGB"), dtype=np.float32)
half = np.asarray(Image.open(sys.argv[2]).convert("RGB"), dtype=np.float32)

# Boxes are for the x48 fixture on HEADLESS-1 at 1920x1080.
CELL = (1000, 1100, 205, 255)   # inside a strip cell, clear of the workspace number
OUTS = (1000, 1100, 350, 400)   # overview backdrop just below the strip
MINI = (815, 860, 240, 270)     # the blue kitty mini preview inside cell 1


def patch(im, box):
    x0, x1, y0, y1 = box
    return im[y0:y1, x0:x1].mean(axis=(0, 1))


fails = []

# CONTROL: the backdrop beside the strip is not part of the fade and must not
# move at all. If it does, something other than the chrome changed between the
# two builds and nothing below is attributable to alpha.
ctl = float(np.abs(patch(full, OUTS) - patch(half, OUTS)).mean())
print(f"CONTROL backdrop beside the strip: {np.round(patch(full, OUTS), 1)} vs {np.round(patch(half, OUTS), 1)}  (delta {ctl:.2f})")
if ctl > 1.0:
    fails.append(f"the backdrop beside the strip moved by {ctl:.2f} -- the two captures are not comparable")

# The cell must lose contrast against that backdrop.
cf = float(np.abs(patch(full, CELL) - patch(full, OUTS)).mean())
ch = float(np.abs(patch(half, CELL) - patch(half, OUTS)).mean())
print(f"strip cell vs backdrop contrast: FADE=1 {cf:.2f}   FADE=0.5 {ch:.2f}   ratio {ch / cf:.2f}")
if ch > cf * 0.85:
    fails.append(f"the strip cell barely faded ({ch:.2f} vs {cf:.2f}) -- the tint is not multiplied")

# The MINI is the one that could silently not fade: it is a live window, and
# the plugin forces window alpha to 1 every frame (E8-f). It must blend toward
# the backdrop like everything else.
mf, mh = patch(full, MINI), patch(half, MINI)
print(f"mini preview: FADE=1 {np.round(mf, 1)}   FADE=0.5 {np.round(mh, 1)}")
if float(np.abs(mf - mh).mean()) < 15.0:
    fails.append("the strip's live window preview did not fade -- the window-alpha modulation is not taking")

print()
if fails:
    for f in fails:
        print("FAIL:", f)
    sys.exit(1)
print("FADE ALPHA PASS: chrome tint and live minis both scale with the fade factor, "
      "and the backdrop beside them does not move")
