#!/usr/bin/env bash
# usage: x24_dock_click.sh <icon-index|gutter> [shift]   -- click a dock cell.
#
# Icon centres are computed from Dock.cpp's own constants rather than read back
# from the plugin, deliberately: the rig PREDICTS where a cell must be and the
# click has to land on it. If the layout and the prediction disagree, the wrong
# app minimizes (or none does) and the gate fails -- which is the point. A rig
# that asked the plugin where to click could never catch a layout bug.
#
# The press is HELD ~120ms with sub-threshold jitter, per x43_click.sh: a
# press+release in the same instant does not exercise the real path.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
OUT=/mnt/host/x24d
TARGET=$1
SHIFT=${2:-noshift}

# x45dock_cell.py is the corrected post-X46 predictor (no preview slots),
# rewired here at promotion; it was previously read from /mnt/host/x24_cell.py.
read -r CX CY <<< "$(hyprctl clients -j | python3 "$(dirname "$0")/x45dock_cell.py" "$TARGET")"
[ -n "${CX:-}" ] || { echo "no dock cell predicted for $TARGET" >&2; exit 1; }

# warp() comes from rig.sh and owns the ydotool halving.

hyprctl clients -j    > $OUT/pre-clients.json
hyprctl activewindow -j > $OUT/pre-active.json

warp $CX $CY; sleep 0.5
[ "$SHIFT" = shift ] && ydotool key 42:1 && sleep 0.1
ydotool click 0x40                       # press, no release
for d in 2 -2 3 -1 0; do warp $((CX+d)) $((CY-d)); sleep 0.025; done
ydotool click 0x80                       # release
[ "$SHIFT" = shift ] && ydotool key 42:0
sleep 1.5

hyprctl clients -j      > $OUT/post-clients.json
hyprctl activewindow -j > $OUT/post-active.json
echo "CLICKED target=$TARGET at $CX,$CY shift=$SHIFT"
