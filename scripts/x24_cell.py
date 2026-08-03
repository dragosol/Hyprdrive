#!/usr/bin/env python3
"""Predict a dock cell's centre from Dock.cpp's own constants. Reads `hyprctl
clients -j` on stdin, prints "X Y" in monitor pixels.

Deliberately a PREDICTION rather than a read-back from the plugin: the rig has
to say where a cell must be and the click has to land on it. A rig that asked
the plugin where to click could never catch a layout bug.

usage: hyprctl clients -j | x24_cell.py <class|gutter>
"""
import json
import sys

# Dock.cpp constants -- keep in step with it.
ITEM_PAD_TOP, ITEM_PAD_BOTTOM = 18.0, 20.0
ITEM_MARGIN_X, CONTAINER_PAD_X, EDGE_MARGIN = 8.0, 8.0, 4.0
HOVER_PAD = 6.0
ICON_MAX, FRACTION = 54.0, 0.90
MW, MH = 2560.0, 1600.0
STASH = "special:minimized"

seen, classes, previews = set(), [], []
for c in json.load(sys.stdin):
    if not c["mapped"] or not c["class"]:
        continue
    if c["class"] not in seen:
        seen.add(c["class"])
        classes.append(c["class"])
    # A minimized window keeps its icon AND adds a preview slot, so the pill
    # grows and every icon centre shifts left. Ignoring that aimed a click ~35px
    # off the cell it named.
    if c["workspace"]["name"] == STASH:
        w, h = c["size"]
        previews.append(min(2.20, max(0.60, w / float(h))) if h else 1.0)

slots = float(len(classes) + len(previews))
units = float(len(classes)) + sum(previews)
chrome = 2 * CONTAINER_PAD_X + 2 * ITEM_MARGIN_X * slots
icon = max(8.0, min(ICON_MAX, (FRACTION * MW - chrome) / max(units, 0.01)))
width = chrome + icon * units
height = ITEM_PAD_TOP + ITEM_PAD_BOTTOM + icon
xl, yl = (MW - width) / 2.0, MH - EDGE_MARGIN - height

target = sys.argv[1]
if target == "gutter":
    # Inside the pill, outside every cell: cells are inset from the pill edge by
    # ITEM_PAD_TOP - HOVER_PAD, so this sits in that margin.
    print(int(xl + 2), int(yl + height / 2))
else:
    # Address the cell by CLASS, not by ordinal: the dock's order is the
    # compositor's window order and the rig must not assume it.
    if target not in classes:
        sys.exit("class %s is not in the dock: %s" % (target, classes))
    i = classes.index(target)
    cx = xl + CONTAINER_PAD_X + ITEM_MARGIN_X + i * (icon + 2 * ITEM_MARGIN_X) + icon / 2
    print(int(cx), int(yl + ITEM_PAD_TOP + icon / 2))
