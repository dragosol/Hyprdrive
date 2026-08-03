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
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t $XDG_RUNTIME_DIR/hypr | head -1)
OUT=/mnt/host/x26

mv() { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )); sleep 0.2; }

case "$1" in
off)
    mv 200 400
    sleep 1.0
    grim -o Virtual-1 $OUT/hover_off.png
    echo parked
    ;;
on)
    mv $2 $3
    sleep 1.2
    grim -o Virtual-1 $OUT/hover_on.png
    echo "hovered $2,$3"
    ;;
esac
