#!/usr/bin/env bash
# Capture the overview at rest so the host can locate the RED (BOT) tile.
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/x43
MON=$(hyprctl monitors -j | python3 -c "
import json,sys
print(next((m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')), ''))")
ov() { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }
ov off; sleep 1.2
ov on;  sleep 3
grim -o $MON $OUT/ovr.png
ov off; sleep 1.2
echo X43_OVR_CAPTURED
