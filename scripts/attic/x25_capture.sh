#!/bin/bash
# X25 capture rig. Runs IN THE GUEST; analysis is on the host (no PIL here).
#
# The question this rig has to answer is not "is there a preview" but "is it
# LIVE" -- a stale screenshot in the dock would pass any single-frame test. So
# the fixture repaints its WHOLE surface on a 1s cycle: liveness then shows up
# as consecutive frames differing, and the changed blob IS the preview box,
# which measures it at the same time.
#
# Virtual-1 only flips while the host's virt-viewer window is drawn, and while
# it is enabled-but-stalled it starves EVERY output. So this runs headless with
# Virtual-1 disabled -- otherwise every frame comes back byte-identical and the
# rig reports "frozen" no matter what the code does. Reboot the guest after.
set -u
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t $XDG_RUNTIME_DIR/hypr | head -1)
OUT=/mnt/host/x25/shots

dispatch() { hyprctl eval "return hl.dispatch($1)" >/dev/null; }

# hyprwall.timer repaints the whole screen every 3 min, which would swamp any
# frame-to-frame comparison. Same trap as the X7 rig.
systemctl --user stop hyprwall.timer
trap 'systemctl --user start hyprwall.timer; kill %1 %2 2>/dev/null' EXIT

# `output create headless` is NOT idempotent: tear down first, build exactly one.
for m in $(hyprctl monitors all | awk '/^Monitor HEADLESS/{print $2}'); do
    hyprctl output remove "$m" >/dev/null
done
hyprctl output create headless >/dev/null
sleep 1
hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = true})" >/dev/null
sleep 2

# Workspaces and modes carry their own "name" keys, so read the plain listing.
MON=$(hyprctl monitors | awk '/^Monitor /{print $2}')
N=$(printf '%s\n' "$MON" | wc -l)
[ "$N" = 1 ] || { echo "ABORT: $N enabled monitors: $MON"; exit 1; }
echo "output: $MON"
shot() { grim -o "$MON" $OUT/$1.png; }

# x25keep stays VISIBLE and flipping for the whole run. It is the control that
# tells a frozen PREVIEW apart from a compositor that stopped rendering at all --
# both of which produce byte-identical frames and would otherwise read the same.
kitty --class x25keep sh -c 'while :; do printf "\033]11;#10e010\007"; sleep 1; printf "\033]11;#e0e010\007"; sleep 1; done' &
sleep 3
kitty --class x25flip sh -c 'while :; do printf "\033]11;#e01010\007"; sleep 1; printf "\033]11;#1010e0\007"; sleep 1; done' &
sleep 5

echo "focused: $(hyprctl activewindow -j | grep -o '"class": "[^"]*"' | head -1)"

# Controls: the dock as it is with nothing minimized. Two of them, so a
# frame-to-frame difference measured later has a baseline on this side too --
# and so the host can certify the output was actually flipping during the run.
shot pre0
sleep 0.8
shot pre1

dispatch "hl.plugin.scrolloverview.minimize([[window]])"
sleep 2

# 0.8s apart against a 1s half-cycle: no two consecutive frames can land on the
# same phase, so a frozen preview cannot fake its way through all four pairs.
for i in 0 1 2 3 4; do
    shot live$i
    sleep 0.8
done

# Dumped WHILE minimized so the gate can predict the preview box from the real
# window size and monitor scale rather than accepting whatever blob it finds.
hyprctl monitors -j > $OUT/monitors.json
hyprctl clients -j > $OUT/clients.json

dispatch "hl.plugin.scrolloverview.minimize([[restore]])"
sleep 2
shot post

echo "clients: $(hyprctl clients -j | grep -c '"class"')"
echo "captured"
