#!/usr/bin/env bash
# X52: profile the KEYSTROKE-TO-PAINT path of the search. Runs IN THE GUEST.
#
# The standing rule is to measure the moment being complained about. That moment
# starts when a key is pressed and ends when the frame carrying the new results
# is painted -- which is neither steady-state frame cost nor open/close
# time-to-settle, the two things this project has already instrumented.
#
# Requires a plugin built with the Prof:: counters and SCROLLOVERVIEW_PROFILE=1
# in the COMPOSITOR's environment (custom/env.lua), because the plugin reads it.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
LOG=/tmp/scrolloverview-prof.log

dsp() { hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }
ov()  { dsp "hl.plugin.scrolloverview.overview([[$1]])"; }
key() { ydotool key "$1:1" "$1:0"; sleep 0.45; }

N=${1:-12}

systemctl --user stop hyprwall.timer 2>/dev/null
ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5

# Spread over four workspaces so the grid, the strip and the cross-workspace
# promotion path are all exercised -- a one-workspace fixture would profile a
# code path the user never uses.
for i in $(seq 1 $N); do
    dsp "hl.dsp.focus({workspace = $(( (i % 4) + 1 ))})"; sleep 0.12
    setsid kitty -c NONE --class X52W$i -o background='#334455' -o background_opacity=1.0 \
        -o confirm_os_window_close=0 --hold sh -c clear >/dev/null 2>&1 </dev/null &
    sleep 0.9
done
sleep 1.5
dsp "hl.dsp.focus({workspace = 1})"; sleep 0.8
echo "windows: $(hyprctl clients -j | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"

ov on; sleep 2.5
: > $LOG

# k, i, t -- a query that narrows from "everything" to "a few", which is the
# shape of the complaint.
key 37; key 23; key 20
sleep 1.5

echo "--- $LOG ---"
cat $LOG
ov off
