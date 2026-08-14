#!/usr/bin/env bash
# usage: z3_shot.sh <tag>
# Photograph the overview WITHOUT touching it. The point of this script is what
# it does not do: attic/z3_view.sh closes and reopens, which destroys CScrollOverview
# and every piece of drag state it holds -- so a second drag taken after it is a
# first drag wearing a different name.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
OUT=/mnt/host/z3
MON=$(hyprctl monitors -j | python3 -c "
import json,sys
print(next((m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')), ''))")
grim -o $MON $OUT/$1.png
echo "shot: $OUT/$1.png"
