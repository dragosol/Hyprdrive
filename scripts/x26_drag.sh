#!/bin/bash
# X26 drag from the overview into the dock. Runs IN THE GUEST, overview open.
#   x26_drag.sh <grabX> <grabY> <dropX> <dropY> <name>
# Every coordinate is measured on the HOST off a frame from THIS run: the tile
# moves with the window count and the pill is centred, so both drift.
# Coordinates are SCREEN px; ydotool's absolute space here is half the output.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
OUT=/mnt/host/x26
GX=$1; GY=$2; TX=$3; TY=$4; NAME=$5

mv() { warp "$1" "$2"; sleep 0.05; }   # rig.sh warp owns the halving; pacing stays here
# Absolute jumps read as one teleport; the overview's drag threshold and its
# per-motion hover work both want a stream of moves. Interpolate every leg.
glide() { # glide <x0> <y0> <x1> <y1>
    for i in $(seq 1 12); do
        mv $(( $1 + ($3 - $1) * i / 12 )) $(( $2 + ($4 - $2) * i / 12 ))
    done
}

mv $GX $GY
ydotool click 0x40   # press and hold
sleep 0.3
# Past the drag threshold, then settle over its OWN workspace: this frame is the
# unshrunk reference the over-the-dock frame is compared against.
glide $GX $GY $(( GX + 90 )) $(( GY + 60 ))
sleep 0.9
grim -o Virtual-1 $OUT/drag_home_$NAME.png

glide $(( GX + 90 )) $(( GY + 60 )) $TX $TY
mv $TX $TY
sleep 1.2
grim -o Virtual-1 $OUT/drag_over_$NAME.png

ydotool click 0x80   # release
sleep 1.5
grim -o Virtual-1 $OUT/post_$NAME.png
hyprctl clients -j > $OUT/clients_$NAME.json
echo "dropped at $TX,$TY ($NAME)"
