#!/usr/bin/env bash
# Does a tap DURING the close animation bring the overview back?
#
# Three captures, and the comparison is what proves it rather than any single
# frame: OPEN is what an overview looks like, SHUT is what the desktop looks
# like, and REVERSED is the one under test. REVERSED must land on OPEN. Before
# this change it landed on SHUT -- the second tap was swallowed whole.
#
# The close animation is windowsMove, speed 3.00 = ~300ms, so the second tap
# goes in at 120ms: far enough in that the animation is genuinely running, early
# enough that it has not already ended.
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=$(basename $(ls -t /run/user/1000/wayland-* | grep -v lock | head -1))
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/reopenshots
mkdir -p $OUT

read -r MON W H <<< "$(hyprctl monitors -j | python3 -c "
import json,sys
m = json.load(sys.stdin)[0]
print(m['name'], m['width'], m['height'])")"

dsp()  { hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }
tog()  { dsp "hl.plugin.scrolloverview.overview([[toggle]])"; }
warp() { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; sleep 0.3; }
park() { warp $((W / 2)) $((H / 3)); }
shot() { sleep 0.6; grim -o "$MON" $OUT/$1.png; }

case "${1:?usage: reopen_rig.sh <fixture|run>}" in

fixture)
    systemctl --user stop hyprwall.timer 2>/dev/null
    systemd-run --user --on-active=40min systemctl --user start hyprwall.timer >/dev/null 2>&1
    dsp "hl.plugin.scrolloverview.overview([[off]])"; sleep 1.0
    pkill -f kitty 2>/dev/null; sleep 1.0
    for i in 1 2; do
        setsid -f kitty --override background=#20${i}0${i}0 -o confirm_os_window_close=0 \
            sh -c 'while :; do sleep 1; done' </dev/null >/dev/null 2>&1
        sleep 1.2
    done
    sleep 1.5
    echo "FIXTURE clients=$(hyprctl clients -j | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
    ;;

run)
    # 1. OPEN -- the reference for "the overview is up".
    dsp "hl.plugin.scrolloverview.overview([[off]])"; sleep 1.5
    tog; sleep 3.0; park; sleep 1.0; shot open

    # 2. SHUT -- close and let it finish. The reference for "it went away".
    tog; sleep 3.0; park; sleep 1.0; shot shut

    # 3. OPEN2 -- a plain open taken in the SAME cycle position as the reversal
    #    below. Without it the reversal is being compared against a frame two
    #    open/close cycles older, and any drift the cycling itself causes would
    #    be charged to the reversal.
    tog; sleep 3.0; park; sleep 1.0; shot open2
    tog; sleep 3.0

    # 4. REVERSED -- open, settle, close, and tap again 120ms in.
    tog; sleep 3.0; park; sleep 1.0
    tog
    sleep 0.12
    tog
    sleep 3.0; park; sleep 1.0; shot reversed

    dsp "hl.plugin.scrolloverview.overview([[off]])"
    echo "REOPEN rig done -> $OUT"
    ;;

*) echo "unknown $1"; exit 2 ;;
esac
