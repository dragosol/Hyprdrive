#!/usr/bin/env bash
# X1 drag probe: find a grab point and a strip target that actually move a
# window, so the stress run's drag phase cannot silently no-op.
# ydotool absolute coords are HALF screen coords on this rig (measured: sending
# 100 lands the cursor at 201), hence mv2.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
OUT=/mnt/host/x1; mkdir -p $OUT
MON=$(hyprctl monitors -j | python3 -c "
import json,sys
print(next((m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')), ''))")
# ov() comes from rig.sh (verbatim-equivalent)
mv2() { warp "$1" "$2"; }    # rig.sh warp owns the ydotool halving now
walk(){ local n=14 i; for i in $(seq 1 $n); do
    mv2 $(( $1 + ($3 - $1) * i / n )) $(( $2 + ($4 - $2) * i / n )); sleep 0.04; done; }
ws()  { hyprctl workspaces -j | python3 -c "import json,sys; print(' '.join('%d:%d'%(w['id'],w['windows']) for w in sorted(json.load(sys.stdin),key=lambda x:x['id'])))"; }

# Defaults are the magenta ws1 tile (measured box x=[210,559] y=[423,633]) and a
# strip cell. Screen centre is NOT on a tile -- it lands in a gap, the press is
# swallowed and the release reads as a click on the backdrop, which closes the
# overview. That false lead cost a run.
GX=${GX:-384}; GY=${GY:-528}; TX=${TX:-1210}; TY=${TY:-190}

ov off; sleep 1.2
ov on;  sleep 2.5
B=$(ws); echo "before: $B"
grim -o $MON $OUT/dragprobe-0-rest.png

mv2 $GX $GY; sleep 0.6
ydotool click 0x40; sleep 0.4
walk $GX $GY $((GX-80)) $((GY-120)); sleep 0.4
grim -o $MON $OUT/dragprobe-1-middrag.png
walk $((GX-80)) $((GY-120)) $TX $TY; sleep 1.2
grim -o $MON $OUT/dragprobe-2-overtarget.png
ydotool click 0x80; sleep 2.0
A=$(ws); echo "after:  $A"
mv2 960 900; sleep 1.0
grim -o $MON $OUT/dragprobe-3-settled.png
ov off; sleep 1
[ "$B" != "$A" ] && echo "DRAG_MOVED_A_WINDOW grab=$GX,$GY target=$TX,$TY" || echo "DRAG_NO_MOVE grab=$GX,$GY target=$TX,$TY"
