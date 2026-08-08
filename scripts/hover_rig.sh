#!/usr/bin/env bash
# Does the tile hover OVERSHOOT? Runs IN THE GUEST.
#
# A bounce is a transient: the tile grows past its final size and comes back. So
# the measurement is the tile's WIDTH sampled as fast as the guest will hand
# over frames, against the width it settles at.
#
#   settled = width after the animation has definitely finished
#   peak    = the widest of ~10 samples taken from the moment the hover starts
#
#   easeOutBack overshoots ~10% of the growth, and the growth is 5% of the tile,
#   so on a ~1000px tile the peak sits ~5px past settled. That is the whole
#   signal, which is why the fixture is ONE window (the biggest possible tile)
#   in a saturated colour nothing else on screen shares.
#
# Width is measured on the HOST (no numpy in the guest) -- this script only
# captures. Frames are a horizontal band through the tile's middle, because a
# full-screen grim is ~500ms here and would be slower than the animation.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
OUT=/mnt/host/hover; mkdir -p $OUT

# dsp()/ov()/warp() come from lib/rig.sh (verbatim-equivalent to the old local
# ones; warp owns the ydotool half-space rule, coordinates here stay monitor px).

TAG=${1:?usage: hover_rig.sh <tag>}

systemctl --user stop hyprwall.timer 2>/dev/null
ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5

read -r MON W H <<< "$(hyprctl monitors -j | python3 -c "
import json,sys
m=json.load(sys.stdin)[0]; print(m['name'], m['width'], m['height'])")"

# ONE window: with a single tile the grid gives it the most room, so 5% of it is
# the largest absolute number of pixels this signal can ever be.
setsid kitty -c NONE --class HOVERT -o background='#00ff00' -o background_opacity=1.0 \
    -o confirm_os_window_close=0 --hold sh -c clear >/dev/null 2>&1 </dev/null &
sleep 2.5
hyprctl clients -j | grep -q HOVERT || { echo "ABORT: fixture window missing"; exit 1; }

ov on; sleep 2.5

# Park off the tile, then find the tile's centre from the plugin's own geometry
# rather than guessing: a hit target computed from a stale layout is the trap
# every earlier rig in this repo paid for.
CX=$((W / 2)); CY=$((H / 2))
warp $((W - 40)) $((H - 40)); sleep 1.2

BAND="0,$((CY - 4)) ${W}x8"
shot() { grim -g "$BAND" "$OUT/$TAG-$1.png" 2>/dev/null; }

# Settled-unhovered, for the gate's "the hover did something at all" control.
shot rest

# Hover, sampling immediately and as fast as grim will go.
warp $CX $CY
for i in $(seq 0 9); do shot "s$i"; done

# Long after the animation must have ended.
sleep 1.0
shot settled

warp $((W - 40)) $((H - 40)); sleep 1.0
ov off
ls $OUT/$TAG-*.png | wc -l | sed 's/^/frames: /'
echo HOVER_RIG_OK
