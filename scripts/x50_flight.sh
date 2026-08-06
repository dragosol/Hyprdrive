#!/usr/bin/env bash
# X50 second half: the pill MOVES, it does not cut. Spec says "animate-move".
#
# The query is "k" because both fixture windows match it SYNCHRONOUSLY -- the
# window-match half of the trigger needs no debounce and no provider round
# trip, so the flight starts on the very next frame after the keypress and a
# burst of grims can land inside it. (A provider-only query would start the
# flight seconds later, at a time this script cannot predict.)
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
SRC=/mnt/host/x48; OUT=/mnt/host/x50; mkdir -p $OUT
MON=$(cat $SRC/mon)
TAG=${1:?usage: x50_flight.sh <tag>}

ov() { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }

systemctl --user stop hyprwall.timer 2>/dev/null
ov off; sleep 1.0
ov on;  sleep 2.5
grim -o "$MON" "$OUT/$TAG-f00-rest.png"

ydotool key 37:1 37:0
for i in $(seq 1 6); do grim -o "$MON" "$OUT/$TAG-f$(printf '%02d' "$i").png"; done
sleep 2.5
grim -o "$MON" "$OUT/$TAG-f99-settled.png"

ydotool key 1:1 1:0; sleep 1.0
ov off
systemctl --user start hyprwall.timer 2>/dev/null
ls -la $OUT/$TAG-f*.png
echo X50_FLIGHT_OK
