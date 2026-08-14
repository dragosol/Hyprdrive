#!/usr/bin/env bash
# Find a strip-cell drop target empirically. The strip minis cannot be located
# by colour: the wallpaper is orange/gold and saturates the whole band, and the
# frosted panel lets it through, so every hue mask spans the full width. Trying
# candidate X positions and watching which one actually moves a window is both
# cheaper and decisive.
#
# Stops at the FIRST committing target, because a commit reflows the grid and
# invalidates the grab point for later laps.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
GX=${GX:-512}; GY=${GY:-478}; TY=${TY:-170}
CANDS=${CANDS:-"240 360 480 610 730"}
# ov() comes from rig.sh (verbatim-equivalent)
mv2() { warp "$1" "$2"; }    # rig.sh warp owns the ydotool halving now
walk(){ local n=${5:-12} i; for i in $(seq 1 $n); do
    mv2 $(( $1 + ($3 - $1) * i / n )) $(( $2 + ($4 - $2) * i / n )); sleep 0.04; done; }
occ() { hyprctl workspaces -j | python3 -c "
import json,sys
w=[x for x in json.load(sys.stdin) if x['windows']>0]
print(' '.join('%d:%d'%(x['id'],x['windows']) for x in sorted(w,key=lambda k:k['id'])))"; }

for TX in $CANDS; do
  ov off; sleep 1.0
  ov on;  sleep 2.2
  B=$(occ)
  mv2 $GX $GY; sleep 0.4
  ydotool click 0x40 >/dev/null 2>&1; sleep 0.25
  walk $GX $GY $((GX-60)) $((GY-140)) 6
  walk $((GX-60)) $((GY-140)) $TX $TY 12
  sleep 1.0
  ydotool click 0x80 >/dev/null 2>&1; sleep 1.8
  A=$(occ)
  if [ "$B" != "$A" ]; then
    echo "COMMIT at TX=$TX TY=$TY : $B -> $A"
    ov off; exit 0
  fi
  echo "  no commit TX=$TX ($B)"
done
ov off; sleep 0.5
echo "NO_COMMIT_FOUND candidates: $CANDS"
exit 1
