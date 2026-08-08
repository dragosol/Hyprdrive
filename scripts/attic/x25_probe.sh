#!/bin/bash
# Is the client BLOCKED, or is the compositor not picking up its buffers?
# A client waiting on a frame callback burns no CPU no matter how much its
# content wants to change, so a CPU delta of ~0 while minimized answers it.
#
# Headless with Virtual-1 disabled, same as the capture rig: a stalled Virtual-1
# starves the whole compositor and flattens the VISIBLE baseline too, which made
# the first run of this probe read 0-vs-0 and prove nothing. Reboot the guest after.
set -u
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t $XDG_RUNTIME_DIR/hypr | head -1)

cpu() { awk '{print $14+$15}' /proc/$1/stat 2>/dev/null || echo 0; }
dispatch() { hyprctl eval "return hl.dispatch($1)" >/dev/null; }

for m in $(hyprctl monitors all | awk '/^Monitor HEADLESS/{print $2}'); do
    hyprctl output remove "$m" >/dev/null
done
hyprctl output create headless >/dev/null
sleep 1
hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = true})" >/dev/null
sleep 2
N=$(hyprctl monitors | grep -c '^Monitor ')
[ "$N" = 1 ] || { echo "ABORT: $N enabled monitors"; exit 1; }

kitty --class x25flip sh -c 'while :; do printf "\033]11;#e01010\007"; sleep 0.3; printf "\033]11;#1010e0\007"; sleep 0.3; done' &
trap 'kill %1 2>/dev/null' EXIT
sleep 5

PID=$(pgrep -f 'x25flip' | head -1)
HYPR=$(pgrep -x Hyprland | head -1)
echo "kitty pid=$PID hyprland pid=$HYPR"

A=$(cpu $PID); H=$(cpu $HYPR); sleep 5; B=$(cpu $PID); H2=$(cpu $HYPR)
echo "VISIBLE   kitty=+$((B-A)) ticks   hyprland=+$((H2-H)) ticks"

dispatch "hl.plugin.scrolloverview.minimize([[window]])"
sleep 2
A=$(cpu $PID); H=$(cpu $HYPR); sleep 5; B=$(cpu $PID); H2=$(cpu $HYPR)
echo "MINIMIZED kitty=+$((B-A)) ticks   hyprland=+$((H2-H)) ticks"

dispatch "hl.plugin.scrolloverview.minimize([[restore]])"
sleep 1
echo "probe done"
