#!/usr/bin/env bash
# X27 acceptance capture. The pill is 0.19-alpha frost, so its footprint is not
# findable by colour -- it is found by an A/B against dock:enabled false. That
# also makes the capture unable to pass vacuously: if the dock never drew, the
# two frames are identical and the gate has nothing to measure.
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/x27
mkdir -p $OUT

MON=$(hyprctl monitors -j | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['name'])")

# Four DISTINCT classes: the dock groups by class, so four kitties would size a
# one-icon pill and every proportion assertion would be about a single cell.
pkill -f gtk3-demo; pkill -f gtk3-widget-factory; pkill -f gtk3-icon-browser
sleep 0.5
kitty >/dev/null 2>&1 &
gtk3-demo >/dev/null 2>&1 &
gtk3-widget-factory >/dev/null 2>&1 &
gtk3-icon-browser >/dev/null 2>&1 &
sleep 4

hyprctl clients -j > $OUT/clients.json
hyprctl monitors -j > $OUT/monitors.json

# `hyprctl keyword` is gone in 0.56 -- it answers "keyword can't work with
# non-legacy parsers. Use eval." and exits 0, so a rig that used it toggled
# NOTHING while looking healthy. The first run of this gate did exactly that and
# produced an empty diff that read as "the dock never drew".
key() { hyprctl eval "return hl.config({ plugin = { scrolloverview = { dock = { $1 = $2 } } } })"; }

# Dock-OFF frames on BOTH sides of the ON frame, so the gate can build a NOISE
# mask: a blinking cursor and any live window content churn between captures and
# would otherwise dominate the diff (measured: they did, 1366x817 of it).
# Bracketing matters -- a slow animation can sit still across two consecutive
# frames and only move by the third (measured: a 14x8 spinner in widget-factory).
key enabled false; sleep 1.5; grim -o "$MON" $OUT/off1.png
                   sleep 1.5; grim -o "$MON" $OUT/off2.png
key enabled true;  sleep 1.5; grim -o "$MON" $OUT/on.png
key enabled false; sleep 1.5; grim -o "$MON" $OUT/off3.png

echo "X27_CAPTURED mon=$MON"
