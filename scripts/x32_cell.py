#!/usr/bin/env python3
"""Predict the Show Applications button's centre from Dock.cpp's own constants.
Reads `hyprctl clients -j` on stdin, prints "X Y" in monitor pixels.

Separate from x24_cell.py on purpose. x24's model assumes the button is OFF --
every gate that uses it sets show_apps_button=false -- and the button is a slot
of its own that widens the pill and shrinks every icon (Dock.cpp:1036-1041), so
teaching x24 about it would move predictions under gates that never asked for
it. This one assumes the button is ON, which is the state X32 is about.

A PREDICTION, never a read-back: a rig that asked the plugin where its own
button is could not catch a layout bug (x24_cell.py:5-8).

usage: hyprctl clients -j | x32_cell.py showapps
"""
import json
import sys

# Dock.cpp, X53 block -- keep in step with it.
ICON_GAP, ICON_PAD = 16.0, 14.0
ITEM_MARGIN_X = ICON_GAP / 2.0
CONTAINER_PAD_X = ICON_PAD - ITEM_MARGIN_X
ITEM_PAD_TOP = ICON_PAD
EDGE_MARGIN = 4.0
ICON_MAX, FRACTION = 54.0, 0.90

MW, MH = 2560.0, 1600.0

seen, classes = set(), []
for c in json.load(sys.stdin):
    if not c["mapped"] or not c["class"]:
        continue
    if c["class"] not in seen:
        seen.add(c["class"])
        classes.append(c["class"])

# The button is one more slot AND one more unit (Dock.cpp:1041, 1052).
slots = units = float(len(classes)) + 1.0
chrome = 2 * CONTAINER_PAD_X + 2 * ITEM_MARGIN_X * slots
icon = max(8.0, min(ICON_MAX, (FRACTION * MW - chrome) / max(units, 0.01)))
width = chrome + icon * units
height = 2 * ITEM_PAD_TOP + icon
xl, yl = (MW - width) / 2.0, MH - EDGE_MARGIN - height

target = sys.argv[1] if len(sys.argv) > 1 else "showapps"
if target != "showapps":
    sys.exit("x32_cell.py only predicts 'showapps'")

# show_apps_at_top false + show_apps_always_in_the_edge true (both defaults):
# the button is the LAST slot, after every running icon (Dock.cpp:1088-1096).
i = len(classes)
cx = xl + CONTAINER_PAD_X + ITEM_MARGIN_X + i * (icon + 2 * ITEM_MARGIN_X) + icon / 2
print(int(cx), int(yl + ITEM_PAD_TOP + icon / 2))
