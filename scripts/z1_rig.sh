#!/usr/bin/env bash
# Z1 (user report, 2026-08-07): "If I move a window to another desktop, then I
# look at the dock preview of that window, and I swap desktops back and forth,
# the dock preview disappears."
#
# The rig reproduces exactly that order, because the ORDER is the whole bug:
# a workspace that has only ever RECEIVED a window (silent move) has never been
# animated, so its m_renderOffset is still zero and the preview draws; once it
# has been switched away from, the offset is parked a monitor's width away and
# renderWindow puts the preview there while the clip box stays on the cell.
#
# So there are two hover captures of the SAME window in the SAME state, with
# nothing between them but desktop swaps. A build that draws the first and not
# the second is the reported defect; a build that draws both has fixed it.
#
# CONTROLS ON BOTH SIDES, per the standing rule: an unhovered frame is captured
# before each hover, so "no magenta" cannot pass as a hover that simply never
# happened.
#
# Runs IN THE GUEST. Captures only -- the counting is on the host (no numpy).
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1

TAG=${1:?usage: z1_rig.sh <tag>}
OUT=/mnt/host/z1; mkdir -p $OUT

WS_HOME=1        # where the rig stands
WS_AWAY=7        # never visited before the swap phase -- that is the point

# dsp/ov/warp come from rig.sh (identical bodies; warp owns the halving)
cfg()  { cfg_dock "$1"; }

restore() {   # chained in front of headless_off/hyprwall_resume once headless_on is up
    ov off
    cfg "autohide=true, show_favorites=true, show_apps_button=true, show_trash=true, show_mounts=false"
    dsp "hl.dsp.focus({workspace = $WS_HOME})"
}

hyprwall_pause

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5
dsp "hl.dsp.focus({workspace = $WS_HOME})"; sleep 0.8

# --- headless output, Virtual-1 off (rig.sh headless_on): Virtual-1 draws
# ~1fps with no viewer attached, so grim hands back stale frames and every
# measurement below is a reading of the throttle rather than of the plugin.
RIG_HEADLESS_MODE=2560x1600@60      # this rig was proven at @60; keep it
headless_on || exit 1
trap 'restore; headless_off; hyprwall_resume' EXIT   # chain, per rig.sh contract
MON=$RIG_MON; W=$RIG_W; H=$RIG_H
echo "monitor: $MON ${W}x${H}"

# Running classes only, so x47_cell.py's prediction is a prediction.
cfg "autohide=false, show_favorites=false, show_apps_button=false, show_trash=false, show_mounts=false"
sleep 0.8

# MAGENTA, and the whole window is it. The guest wallpaper has reds and blues in
# it but no saturated magenta -- the c0/c1 controls are what prove that rather
# than the claim.
dsp "hl.dsp.focus({monitor = \"$MON\"})"; sleep 0.3
dsp "hl.dsp.focus({workspace = $WS_HOME})"; sleep 0.4
setsid kitty -c NONE --class Z1A --title Z1AWIN -o background='#ff00ff' -o background_opacity=1.0 \
    -o confirm_os_window_close=0 --hold sh -c 'clear; sleep infinity' >/dev/null 2>&1 </dev/null &
sleep 3

ADDR=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='Z1A'), ''))")
[ -n "$ADDR" ] || { echo "ABORT: Z1A did not appear"; exit 1; }
echo "Z1A: $ADDR"

# --- THE MOVE. Silent, so WS_AWAY is still a workspace that has never been
# shown -- which is what makes the BEFORE capture a working control rather than
# a second copy of the bug.
# `follow = false`, NOT `silent = true`. Probed on this guest: 0.56 accepts any
# key without complaint, and `silent` is not one it reads -- the view followed
# the window, which would have made WS_AWAY a visited workspace and turned the
# BEFORE control into a second copy of the bug.
dsp "hl.dsp.window.move({workspace = $WS_AWAY, window = [[address:$ADDR]], follow = false})"
sleep 1.2
WSNOW=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((str(c['workspace']['id']) for c in json.load(sys.stdin) if c['class']=='Z1A'), '?'))")
[ "$WSNOW" = "$WS_AWAY" ] || { echo "ABORT: Z1A is on ws $WSNOW, wanted $WS_AWAY"; exit 1; }
ACTIVE=$(hyprctl activeworkspace -j | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
[ "$ACTIVE" = "$WS_HOME" ] || { echo "ABORT: the silent move took the view to ws $ACTIVE"; exit 1; }
echo "Z1A moved to ws $WSNOW, still standing on ws $ACTIVE"

read -r IX IY <<< "$(hyprctl clients -j | python3 /mnt/host/x47_cell.py Z1A)"
read -r PX PY PW PH <<< "$(hyprctl clients -j | python3 /mnt/host/x47_cell.py panel)"
echo "icon Z1A=$IX,$IY   predicted panel=$PX,$PY ${PW}x${PH}"
echo "$PX $PY $PW $PH" > $OUT/$TAG-panel.txt

BAND="0,$((PY - 24)) ${W}x$((PH + 24))"
echo "band: $BAND"
shot() { grim -g "$BAND" "$OUT/$TAG-$1.png" 2>/dev/null; }

PARKX=$((W - 60)); PARKY=60

hover() {   # hover the icon, let the panel settle past PANEL_IN_MS, capture
    warp_or_die $IX $IY
    sleep 0.6
    shot "$1"
}

# ============ BEFORE: the desktop has never been swapped ============
ov on; sleep 2.5
warp $PARKX $PARKY; sleep 1.2
shot c0
hover h0
warp $PARKX $PARKY; sleep 1.6
ov off; sleep 1.2

# ============ THE SWAP, back and forth, exactly as reported ============
for i in 1 2; do
    dsp "hl.dsp.focus({workspace = $WS_AWAY})"; sleep 1.4
    dsp "hl.dsp.focus({workspace = $WS_HOME})"; sleep 1.4
done
ACTIVE=$(hyprctl activeworkspace -j | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
[ "$ACTIVE" = "$WS_HOME" ] || { echo "ABORT: swaps left the view on ws $ACTIVE"; exit 1; }
WSNOW=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((str(c['workspace']['id']) for c in json.load(sys.stdin) if c['class']=='Z1A'), '?'))")
[ "$WSNOW" = "$WS_AWAY" ] || { echo "ABORT: the swaps moved Z1A to ws $WSNOW"; exit 1; }
echo "swapped ${WS_HOME}<->${WS_AWAY} twice; Z1A still on ws $WSNOW"

# ============ AFTER: same window, same state, same hover ============
ov on; sleep 2.5
warp $PARKX $PARKY; sleep 1.2
shot c1
hover h1
warp $PARKX $PARKY; sleep 1.6

echo "frames: $(ls $OUT/$TAG-*.png | wc -l)"
echo Z1_RIG_OK
