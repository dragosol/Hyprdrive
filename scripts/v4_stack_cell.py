#!/usr/bin/env python3
"""Predict a dock cell's centre WITH STACKS ON, from Dock.cpp's own constants.

Reads `hyprctl clients -j` on stdin, prints "X Y" in monitor pixels.

A PREDICTION, never a read-back, for the reason x24_cell.py states: a rig that
asked the plugin where its cells are could not catch a layout bug. This is a
second predictor rather than an argument to the first because a stack changes
the ITEM MODEL, and the first one models running classes only.

THE DOCK IS CONFIGURED TO MATCH THIS MODEL, not the other way round. The gate
turns show_favorites, show_trash and show_apps_button OFF before it measures,
so the dock contains exactly:

    [running classes, in compositor window order] ++ [stacks, in store order]

and every term below is then exact rather than approximately right. That is
also why this file does not have to model favourites-that-resolve-on-this-
machine, mounts, or the Show Applications slot: the gate has removed all four
from the question.

usage:
    hyprctl clients -j | v4_stack_cell.py stack <k> <nstacks>   -- kth stack
    hyprctl clients -j | v4_stack_cell.py class <name> <nstacks>
    hyprctl clients -j | v4_stack_cell.py gutter <nstacks>
"""
import json
import sys

# Dock.cpp constants -- keep in step with it (Dock.cpp:135-154).
ITEM_PAD_TOP, ITEM_PAD_BOTTOM = 14.0, 14.0
ITEM_MARGIN_X, CONTAINER_PAD_X, EDGE_MARGIN = 8.0, 6.0, 4.0
ICON_MAX, FRACTION = 54.0, 0.90
MW, MH = 2560.0, 1600.0

seen, classes = set(), []
for c in json.load(sys.stdin):
    if not c["mapped"] or not c["class"]:
        continue
    if c["class"] not in seen:
        seen.add(c["class"])
        classes.append(c["class"])

mode = sys.argv[1]
nstacks = int(sys.argv[-1])

slots = float(len(classes) + nstacks)
units = slots
chrome = 2 * CONTAINER_PAD_X + 2 * ITEM_MARGIN_X * slots
icon = max(8.0, min(ICON_MAX, (FRACTION * MW - chrome) / max(units, 0.01)))
width = chrome + icon * units
height = ITEM_PAD_TOP + ITEM_PAD_BOTTOM + icon
xl, yl = (MW - width) / 2.0, MH - EDGE_MARGIN - height


def centre(i):
    cx = xl + CONTAINER_PAD_X + ITEM_MARGIN_X + i * (icon + 2 * ITEM_MARGIN_X) + icon / 2
    return int(cx), int(yl + ITEM_PAD_TOP + icon / 2)


if mode == "gutter":
    print(int(xl + 2), int(yl + height / 2))
elif mode == "stack":
    k = int(sys.argv[2])
    if k >= nstacks:
        sys.exit("stack %d of %d" % (k, nstacks))
    print("%d %d" % centre(len(classes) + k))
elif mode == "class":
    name = sys.argv[2]
    if name not in classes:
        sys.exit("class %s is not in the dock: %s" % (name, classes))
    print("%d %d" % centre(classes.index(name)))
elif mode == "pill":
    # The whole pill, for a crop: "X Y W H".
    print("%d %d %d %d" % (int(xl), int(yl), int(width), int(height)))
elif mode == "above":
    # A point one pill-height ABOVE the kth stack's cell -- where the fan's
    # first row must be. Used to assert the popup is where it says it is.
    k = int(sys.argv[2])
    cx, _ = centre(len(classes) + k)
    print("%d %d" % (cx, int(yl - 30)))
else:
    sys.exit("unknown mode %s" % mode)
