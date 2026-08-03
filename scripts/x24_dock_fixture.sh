#!/usr/bin/env bash
# X24 dock-side fixture. Runs IN THE GUEST.
#
# Three kitty windows in TWO classes, so the rig can tell "clicked icon 0" from
# "clicked icon 1" -- an icon click that lands on the wrong cell must fail, not
# quietly pass because every window belongs to the same app.
#
# Class X24DUO owns two windows (the `minimize-shift` case), X24SOLO owns one
# (the `activate-single-window` case).
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)

# A wallpaper rotation moves every pixel; nothing here is pixel-based, but the
# repaint churn perturbs timing, so hold it for the run like the X1 rigs do.
systemctl --user stop hyprwall.timer 2>/dev/null
systemd-run --user --on-active=30min systemctl --user start hyprwall.timer >/dev/null 2>&1

pkill -f 'kitty --class X24' 2>/dev/null
sleep 0.5

for c in X24DUO X24DUO X24SOLO; do
    kitty --class "$c" -o confirm_os_window_close=0 sh -c 'while :; do sleep 1; done' &
    sleep 0.9
done
sleep 1.5

hyprctl clients -j > /mnt/host/x24d/clients-fixture.json
echo "FIXTURE_READY"
hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c['class'].startswith('X24'):
        print(' ', c['class'], c['address'], c['workspace']['name'])
"
