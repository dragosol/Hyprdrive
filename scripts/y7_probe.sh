#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC §13.14 Y7 — "I want the dock to start glowing with increasing
# intensity correlated to the distance of the window I'm dragging to the dock to
# the dock (within a threshold, say, bottom 30% of the screen)."
#
# The requirement the spec singles out is CONTINUITY: "a glow that switches on at
# a boundary is not correlated to the distance". So the probe does not ask "is
# there a glow", it samples the SAME live drag at a ladder of heights and hands
# the host one frame per rung.
#
# THE DRAG STAYS AT x=200, hard left. dragGlow() is a function of the cursor's Y
# alone, so nothing is lost by it -- and it keeps the dragged window's proxy,
# which is ~900px wide and follows the cursor, from covering the pill whose halo
# is being measured. A rig that dragged straight down the middle would be
# photographing the proxy.
#
# usage: y7_probe.sh <grabX> <grabY>
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/y7; mkdir -p $OUT

GX=$1; GY=$2
DRAGX=200

read -r MON W H <<< "$(hyprctl monitors -j | python3 -c "
import json,sys
m=json.load(sys.stdin)[0]; print(m['name'], m['width'], m['height'])")"
cfg() { hyprctl eval "hl.config({plugin={scrolloverview={dock={$1}}}}) return 0" >/dev/null 2>&1; }
cfg "autohide=false"
sleep 0.6

mv2()  { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; }
walk() { local n=10 i; for i in $(seq 1 $n); do
    mv2 $(( $1 + ($3 - $1) * i / n )) $(( $2 + ($4 - $2) * i / n )); sleep 0.04; done; }

# The band top the plugin uses: bottom 30% of the output.
BANDTOP=$(( H * 70 / 100 ))
echo "monitor ${W}x${H}  bandtop=$BANDTOP"

# Above the band, then five rungs from the band's top edge to the pill.
YS="$(( BANDTOP - 90 )) $BANDTOP $(( BANDTOP + (H - 90 - BANDTOP) * 1 / 4 )) $(( BANDTOP + (H - 90 - BANDTOP) * 2 / 4 )) $(( BANDTOP + (H - 90 - BANDTOP) * 3 / 4 )) $(( H - 90 ))"
echo "rungs: $YS"
echo "$YS" > $OUT/rungs.txt

mv2 $GX $GY; sleep 0.6
ydotool click 0x40; sleep 0.15          # press and HOLD
walk $GX $GY $DRAGX $(( BANDTOP - 90 )) # into the drag, above the band
sleep 0.8

i=0
PREV=$(( BANDTOP - 90 ))
for y in $YS; do
    walk $DRAGX $PREV $DRAGX $y
    PREV=$y
    sleep 0.7
    grim -o $MON "$OUT/rung$i.png" 2>/dev/null
    i=$((i+1))
done

# Back up out of the band and release on the card it came from: a release inside
# the band but off the pill is still a move, and this run is about the glow.
walk $DRAGX $PREV $GX $GY; sleep 0.5
ydotool click 0x80; sleep 1.5
cfg "autohide=true"
echo "frames: $i"
echo Y7_PROBE_OK
