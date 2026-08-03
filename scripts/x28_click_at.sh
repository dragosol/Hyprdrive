#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC 13.9 X28. Click at absolute monitor coords, IN THE GUEST.
# usage: x28_click_at.sh <button:left|right|hover> <x> <y> <shot-name>
#
# `hover` moves without clicking, so the gate can MEASURE a menu row from its
# hover highlight instead of re-deriving row heights renderText decides.
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/x28
MON=$(awk '{print $2}' $OUT/monitor.txt)

BTN=$1; X=$2; Y=$3; NAME=$4
case "$BTN" in
    left)  DOWN=0x40; UP=0x80 ;;
    right) DOWN=0x41; UP=0x81 ;;
    hover) DOWN=""; UP="" ;;
    *) echo "ABORT: bad button $BTN"; exit 1 ;;
esac

# ydotool's motion space is half the output (see x24_dock_click.sh).
ydotool mousemove -a -x $((X / 2)) -y $((Y / 2)); sleep 0.25
ydotool mousemove -a -x $((X / 2 + 1)) -y $((Y / 2)); sleep 0.10
ydotool mousemove -a -x $((X / 2)) -y $((Y / 2)); sleep 0.35

if [ -n "$DOWN" ]; then
    ydotool click $DOWN; sleep 0.12; ydotool click $UP
fi
sleep 1.2

grim -o $MON $OUT/$NAME.png
hyprctl clients -j > $OUT/clients-$NAME.json
FAV="${XDG_STATE_HOME:-$HOME/.local/state}/scrolloverview/favorites"
cp "$FAV" $OUT/favorites-$NAME.txt 2>/dev/null || : > $OUT/favorites-$NAME.txt
echo "CLICK_OK $BTN $X $Y -> $NAME"
