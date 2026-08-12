#!/bin/bash
# Dock hover highlight + tooltip. Runs IN THE GUEST, overview already open.
#   x26_hover.sh off             -> park the pointer away, shoot the control
#   x26_hover.sh on <x> <y>      -> hover that point, shoot the hover frame
#
# Two phases because the pill is CENTRED and its width tracks the number of
# running apps, so its position moves whenever the fixture does. Measuring the
# target off `open.png` and hovering minutes later aimed 19 px outside the pill
# and read as "the highlight does not render". The control frame is now the same
# frame the target is measured from.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
OUT=/mnt/host/x26

mv() { warp "$1" "$2"; sleep 0.2; }   # rig.sh warp owns the halving; pacing stays here

case "$1" in
off)
    mv 200 400
    sleep 1.0
    grim -o Virtual-1 $OUT/hover_off.png
    # TWO parked frames, the same distance apart as the hover pair. The gate's
    # idle control used to be band_diff(hover_off, hover_off) -- a file compared
    # with ITSELF, which is 0 by construction and can never fail. A control that
    # cannot fail is not a control; this one can.
    sleep 1.2
    grim -o Virtual-1 $OUT/hover_off2.png
    echo parked
    ;;
on)
    mv $2 $3
    sleep 1.2
    grim -o Virtual-1 $OUT/hover_on.png
    echo "hovered $2,$3"
    ;;
esac
