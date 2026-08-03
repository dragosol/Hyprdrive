#!/usr/bin/env python3
"""Predict a dock cell's centre from Dock.cpp's own constants, on whatever
output the rig is using. Reads `hyprctl clients -j` on stdin, prints "X Y" in
monitor pixels.

Same deliberate PREDICTION as x24_cell.py -- a rig that asked the plugin where
to click could never catch a layout bug -- but the monitor size is read rather
than hardcoded, because the X28 rig runs on a headless output (Virtual-1 draws
~1fps while no viewer is attached, which starves every pixel capture).

usage: hyprctl clients -j | x28_cell.py <class|gutter> <monitor-w> <monitor-h>
"""
import json
import sys

# Dock.cpp constants -- keep in step with it.
ITEM_PAD_TOP = 12.0
ITEM_MARGIN_X, CONTAINER_PAD_X, EDGE_MARGIN = 2.0, 10.0, 4.0
ICON_MAX, FRACTION = 54.0, 0.90
STASH = "special:minimized"

target = sys.argv[1]
MW, MH = float(sys.argv[2]), float(sys.argv[3])

seen, classes, previews = set(), [], []
for c in json.load(sys.stdin):
    if not c["mapped"] or not c["class"]:
        continue
    if c["class"] not in seen:
        seen.add(c["class"])
        classes.append(c["class"])
    if c["workspace"]["name"] == STASH:
        w, h = c["size"]
        previews.append(min(2.20, max(0.60, w / float(h))) if h else 1.0)

slots = float(len(classes) + len(previews))
units = float(len(classes)) + sum(previews)
chrome = 2 * CONTAINER_PAD_X + 2 * ITEM_MARGIN_X * slots
icon = max(8.0, min(ICON_MAX, (FRACTION * MW - chrome) / max(units, 0.01)))
width = chrome + icon * units
height = 2 * ITEM_PAD_TOP + icon
xl, yl = (MW - width) / 2.0, MH - EDGE_MARGIN - height

if target == "gutter":
    print(int(xl + 2), int(yl + height / 2))
elif target == "pill":
    print(int(xl), int(yl), int(width), int(height))
else:
    if target not in classes:
        sys.exit("class %s is not in the dock: %s" % (target, classes))
    i = classes.index(target)
    cx = xl + CONTAINER_PAD_X + ITEM_MARGIN_X + i * (icon + 2 * ITEM_MARGIN_X) + icon / 2
    print(int(cx), int(yl + ITEM_PAD_TOP + icon / 2))
