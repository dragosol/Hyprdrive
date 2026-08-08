#!/usr/bin/env bash
# Is the motion we see on a minimize the PLUGIN'S flight, or HYPRLAND'S own
# animation of the workspace move that Minimize::minimize performs?
#
# One knob, two extremes. dock:minimize_ms is the flight's whole duration. If the
# visible motion lasts the same either way, the flight is not what is on screen.
# anim_scale stays 1 so nothing else is in the way.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/film; mkdir -p $OUT
cfg(){ hyprctl eval "hl.config({plugin={scrolloverview={dock={$1}}}}) return 0" >/dev/null 2>&1; }
ov(){ hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }
hyprctl eval "hl.config({plugin={scrolloverview={anim_scale=1}}}) return 0" >/dev/null 2>&1
cfg "autohide=false"; sleep 0.5

run() {
    local MS=$1
    cfg "minimize_ms=$MS"; sleep 0.6
    echo "minimize_ms readback: $(hyprctl getoption plugin:scrolloverview:dock:minimize_ms|head -1)"
    pkill -x kitty 2>/dev/null; sleep 1.2
    setsid kitty -c NONE --class FILM --title FILMWIN -o background='#20406a' -o background_opacity=1.0 \
      -o font_size=34 -o confirm_os_window_close=0 --hold sh -c 'yes "FLIGHT AB" | head -24' >/dev/null 2>&1 </dev/null &
    sleep 3
    ov on; sleep 2.5
    rm -f $OUT/ab$MS.mp4
    wf-recorder -f $OUT/ab$MS.mp4 -c libvpx-vp9 -r 30 >/dev/null 2>&1 &
    local W=$!
    sleep 2
    hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.minimize())" >/dev/null 2>&1
    sleep 7
    kill -INT $W 2>/dev/null; wait $W 2>/dev/null
    sleep 1
}
run 100
run 4000
cfg "minimize_ms=400, autohide=true"
ls -la $OUT/ab100.mp4 $OUT/ab4000.mp4 2>/dev/null | awk '{print $NF, $5}'
