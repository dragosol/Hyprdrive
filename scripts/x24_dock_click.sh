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
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/x24d
TARGET=$1
SHIFT=${2:-noshift}

read -r CX CY <<< "$(hyprctl clients -j | python3 /mnt/host/x24_cell.py "$TARGET")"

mv2() { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; }

hyprctl clients -j    > $OUT/pre-clients.json
hyprctl activewindow -j > $OUT/pre-active.json

mv2 $CX $CY; sleep 0.5
[ "$SHIFT" = shift ] && ydotool key 42:1 && sleep 0.1
ydotool click 0x40                       # press, no release
for d in 2 -2 3 -1 0; do mv2 $((CX+d)) $((CY-d)); sleep 0.025; done
ydotool click 0x80                       # release
[ "$SHIFT" = shift ] && ydotool key 42:0
sleep 1.5

hyprctl clients -j      > $OUT/post-clients.json
hyprctl activewindow -j > $OUT/post-active.json
echo "CLICKED target=$TARGET at $CX,$CY shift=$SHIFT"
