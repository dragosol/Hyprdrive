#!/usr/bin/env python3
"""Predict a dock icon centre and the X47 panel's rectangle from Dock.cpp's own
constants. Reads `hyprctl clients -j` on stdin.

A PREDICTION, never a read-back -- the same rule x45dock_cell.py states: a rig
that asked the plugin where the panel is could not catch a layout bug. Keep the
constants below in step with Dock.cpp.

usage: hyprctl clients -j | x47_cell.py <class|panel|gutter>
"""
import json
import sys

# Dock.cpp, X53 block.
HOVER_PAD, ICON_GAP, ICON_PAD = 6.0, 16.0, 14.0
ITEM_MARGIN_X = ICON_GAP / 2.0
CONTAINER_PAD_X = ICON_PAD - ITEM_MARGIN_X
ITEM_PAD_TOP = ITEM_PAD_BOTTOM = ICON_PAD
EDGE_MARGIN = 4.0
ICON_MAX, FRACTION = 54.0, 0.90

# Dock.cpp, X47 block.
PANEL_GAP, PANEL_PAD, PANEL_CELL_H, PANEL_CELL_GAP = 8.0, 10.0, 132.0, 10.0
PREVIEW_MIN_ASPECT, PREVIEW_MAX_ASPECT = 0.60, 2.20

MW, MH = 2560.0, 1600.0

seen, classes, sizes = set(), [], {}
for c in json.load(sys.stdin):
    if not c["mapped"] or not c["class"]:
        continue
    if c["class"] not in seen:
        seen.add(c["class"])
        classes.append(c["class"])
    sizes.setdefault(c["class"], []).append(c["size"])

slots = units = float(len(classes))
chrome = 2 * CONTAINER_PAD_X + 2 * ITEM_MARGIN_X * slots
icon = max(8.0, min(ICON_MAX, (FRACTION * MW - chrome) / max(units, 0.01)))
width = chrome + icon * units
height = ITEM_PAD_TOP + ITEM_PAD_BOTTOM + icon
xl, yl = (MW - width) / 2.0, MH - EDGE_MARGIN - height


def icon_cx(cls):
    if cls not in classes:
        sys.exit("class %s is not in the dock: %s" % (cls, classes))
    i = classes.index(cls)
    return xl + CONTAINER_PAD_X + ITEM_MARGIN_X + i * (icon + 2 * ITEM_MARGIN_X) + icon / 2


target = sys.argv[1]

if target == "gutter":
    print(int(xl + 2), int(yl + height / 2))
elif target == "panel":
    # The widest panel any icon in this fixture can raise, so the capture band
    # covers whichever one the rig hovers. Height does not depend on the app.
    best = 0.0
    for cls in classes:
        content = 0.0
        for n, (w, h) in enumerate(sizes[cls]):
            a = min(PREVIEW_MAX_ASPECT, max(PREVIEW_MIN_ASPECT, w / float(h))) if h else 1.0
            content += PANEL_CELL_H * a + (PANEL_CELL_GAP if n else 0.0)
        best = max(best, content)

    pw = round(best + 2 * PANEL_PAD)
    ph = round(PANEL_CELL_H + 2 * PANEL_PAD)
    py = round(yl - PANEL_GAP - ph)
    print(int(round(xl)), int(py), int(pw), int(ph))
else:
    print(int(icon_cx(target)), int(yl + ITEM_PAD_TOP + icon / 2))
