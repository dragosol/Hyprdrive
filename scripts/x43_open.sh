#!/usr/bin/env bash
# Capture the overview at rest so the host can locate the RED (BOT) tile.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
OUT=/mnt/host/x43
MON=$(hyprctl monitors -j | python3 -c "
import json,sys
print(next((m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')), ''))")
# ov() comes from lib/rig.sh.
ov off; sleep 1.2
ov on;  sleep 3
grim -o $MON $OUT/ovr.png
ov off; sleep 1.2
echo X43_OVR_CAPTURED
