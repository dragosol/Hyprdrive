#!/usr/bin/env bash
# X1 probe: does a query actually reach the overview's filter?
# Captures the SAME overview with no query, with a subset query, and with a
# query that matches nothing. If those three frames are near-identical, the
# filter phase of the stress run is unfalsifiable and its pass means nothing.
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/x1; mkdir -p $OUT
MON=$(hyprctl monitors -j | python3 -c "
import json,sys
print(next((m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')), ''))")
ov()  { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }
key() { ydotool key "$1:1" "$1:0" 2>/dev/null; }

ov off; sleep 1.5
ov on;  sleep 3
grim -o $MON $OUT/probe-0-noquery.png

for k in 45 2 17 11; do key $k; sleep 0.12; done   # x 1 w 0  -> subset
sleep 2.5
grim -o $MON $OUT/probe-1-subset.png

for i in 1 2 3 4; do key 14; sleep 0.1; done
sleep 1.5
for k in 44 44 44; do key $k; sleep 0.12; done      # z z z -> matches nothing
sleep 2.5
grim -o $MON $OUT/probe-2-none.png

for i in 1 2 3; do key 14; sleep 0.1; done
sleep 1.5
ov off
echo X1_PROBE_OK
