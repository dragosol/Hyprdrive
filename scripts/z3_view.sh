#!/usr/bin/env bash
# usage: z3_view.sh <workspace> <tag>
# Put the overview's main card on <workspace> and photograph it, so the host can
# locate MARK's tile there for the next drag. Closing and reopening rather than
# scrolling: the viewport's resting card is whatever workspace was active, which
# is one dispatcher rather than a wheel gesture whose landing has to be trusted.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/z3

WS=$1; TAG=$2
ov()  { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }
dsp() { hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }
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
