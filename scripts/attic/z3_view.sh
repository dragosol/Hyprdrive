#!/usr/bin/env bash
# usage: z3_view.sh <workspace> <tag>
# Put the overview's main card on <workspace> and photograph it, so the host can
# locate MARK's tile there for the next drag. Closing and reopening rather than
# scrolling: the viewport's resting card is whatever workspace was active, which
# is one dispatcher rather than a wheel gesture whose landing has to be trusted.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
OUT=/mnt/host/z3

WS=$1; TAG=$2
# ov/dsp come from rig.sh (identical expansions)
MON=$(hyprctl monitors -j | python3 -c "
import json,sys
print(next((m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')), ''))")

ov off; sleep 1.4
dsp "hl.dsp.focus({workspace = $WS})"; sleep 1.4
ACTIVE=$(hyprctl activeworkspace -j | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
[ "$ACTIVE" = "$WS" ] || { echo "ABORT: wanted ws $WS, on ws $ACTIVE"; exit 1; }
ov on; sleep 3
grim -o $MON $OUT/$TAG.png
echo "view: ws $WS -> $OUT/$TAG.png"
