#!/usr/bin/env python3
"""Predict a dock cell's centre AFTER X46. Reads `hyprctl clients -j` on stdin.

Deliberately a PREDICTION, not a read-back: the rig has to say where a cell must
be and the click has to land on it. A rig that asked the plugin where to click
could never catch a layout bug.

The difference from x24_cell.py IS the X46 fix. That version had to model a
minimized window adding a preview slot, which widened the pill and shifted every
icon centre ~35px left. There are no preview slots any more, so a minimized
window is simply not a layout input -- which is why this file has no `STASH`
branch and why the same coordinates stay valid across a minimize.

usage: hyprctl clients -j | x45dock_cell.py <class|gutter>
"""
import json
import sys

# Dock.cpp constants -- keep in step with it.
ITEM_PAD_TOP, ITEM_PAD_BOTTOM = 14.0, 14.0
ITEM_MARGIN_X, CONTAINER_PAD_X, EDGE_MARGIN = 8.0, 6.0, 4.0
HOVER_PAD = 6.0
ICON_MAX, FRACTION = 54.0, 0.90
MW, MH = 2560.0, 1600.0

seen, classes = set(), []
for c in json.load(sys.stdin):
    if not c["mapped"] or not c["class"]:
        continue
    if c["class"] not in seen:
        seen.add(c["class"])
        classes.append(c["class"])

slots = float(len(classes))
units = float(len(classes))
chrome = 2 * CONTAINER_PAD_X + 2 * ITEM_MARGIN_X * slots
icon = max(8.0, min(ICON_MAX, (FRACTION * MW - chrome) / max(units, 0.01)))
width = chrome + icon * units
height = ITEM_PAD_TOP + ITEM_PAD_BOTTOM + icon
xl, yl = (MW - width) / 2.0, MH - EDGE_MARGIN - height

target = sys.argv[1]
if target == "gutter":
    print(int(xl + 2), int(yl + height / 2))
else:
    # Address the cell by CLASS, never by ordinal: the dock's order is the
    # compositor's window order and the rig must not assume it.
    if target not in classes:
        sys.exit("class %s is not in the dock: %s" % (target, classes))
    i = classes.index(target)
    cx = xl + CONTAINER_PAD_X + ITEM_MARGIN_X + i * (icon + 2 * ITEM_MARGIN_X) + icon / 2
    print(int(cx), int(yl + ITEM_PAD_TOP + icon / 2))
