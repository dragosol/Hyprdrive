#!/bin/bash
# Exactly which half of the frame loop is broken, counted from the wire.
#
# CPU ticks were too coarse to separate "the client never gets a frame callback"
# from "the client commits and the compositor shows a stale texture" -- both read
# as ~1 tick. WAYLAND_DEBUG logs every message, so the two are just two counters:
#   callback.done  = compositor -> client, "draw again"
#   surface.commit = client -> compositor, "here is new content"
# Headless with Virtual-1 disabled, or the whole compositor stalls and both
# counters go to zero for reasons that have nothing to do with X25.
set -u
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t $XDG_RUNTIME_DIR/hypr | head -1)
LOG=/tmp/x25_wl.log

dispatch() { hyprctl eval "return hl.dispatch($1)" >/dev/null; }
count() { grep -c "$1" $LOG; }

for m in $(hyprctl monitors all | awk '/^Monitor HEADLESS/{print $2}'); do
    hyprctl output remove "$m" >/dev/null
done
hyprctl output create headless >/dev/null
sleep 1
hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = true})" >/dev/null
sleep 2
[ "$(hyprctl monitors | grep -c '^Monitor ')" = 1 ] || { echo "ABORT: not exactly one monitor"; exit 1; }

WAYLAND_DEBUG=1 kitty --class x25flip sh -c 'while :; do printf "\033]11;#e01010\007"; sleep 0.3; printf "\033]11;#1010e0\007"; sleep 0.3; done' 2>$LOG &
trap 'kill %1 2>/dev/null' EXIT
sleep 5

sample() {
    local d0 c0 d1 c1
    d0=$(count 'wl_callback.*done'); c0=$(count 'wl_surface.*commit')
    sleep 5
    d1=$(count 'wl_callback.*done'); c1=$(count 'wl_surface.*commit')
    echo "$1 callbacks=+$((d1-d0))  commits=+$((c1-c0))"
}

sample "VISIBLE  "
dispatch "hl.plugin.scrolloverview.minimize([[window]])"
sleep 2
sample "MINIMIZED"
dispatch "hl.plugin.scrolloverview.minimize([[restore]])"
sleep 1
echo "wldebug done"
