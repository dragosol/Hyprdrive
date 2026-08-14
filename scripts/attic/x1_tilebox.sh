#!/usr/bin/env bash
# Capture the overview at rest so the host can measure a real tile box.
# The guest has no PIL; every frame analysis on this project happens on the
# host, where the share is mounted. Pairs with x1_tilebox.py.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
OUT=/mnt/host/x1; mkdir -p $OUT
MON=$(hyprctl monitors -j | python3 -c "
import json,sys
print(next((m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')), ''))")
# ov() comes from rig.sh (verbatim-equivalent)
ov off; sleep 1.2
ov on;  sleep 3
grim -o $MON $OUT/tilebox-rest.png
ov off; sleep 1
echo TILEBOX_CAPTURED
