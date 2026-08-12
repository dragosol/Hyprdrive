#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC §13.12 X46: a minimize must not add a dock entry, so the
# pill must not change shape. Runs IN THE GUEST.
#
# Measured directly rather than via a click, because the claim IS the geometry.
# The first cut of this rig predicted icon centres from Dock.cpp's constants and
# clicked them -- and missed every time, because the real dock also carries
# favourites, X35's trash/mount locations and the Show Applications button, none
# of which the predictor modelled. Capturing the pill sidesteps the whole
# question of what is in it.
#
# Under the OLD behaviour a minimized window appended a preview slot: the pill
# grew by roughly an icon's width and every cell shifted left ~35px. So "the
# strip is pixel-identical before and after a minimize" is exactly X46.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
OUT=/mnt/host/x46; mkdir -p $OUT
TAG=${1:?usage: x46_rig.sh <tag>}

# dsp()/ov() come from lib/rig.sh (identical bodies lived here first).
STRIP='0,1480 2560x120'

minimized_total() {
    hyprctl clients -j | python3 -c "
import json,sys
print(sum(1 for c in json.load(sys.stdin) if c['workspace']['name']=='special:minimized'))"
}

hyprwall_pause
ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5

for c in X46A X46B; do
    setsid kitty -c NONE --class $c -o background='#405060' -o background_opacity=1.0 \
        -o confirm_os_window_close=0 --hold sh -c clear >/dev/null 2>&1 </dev/null &
    sleep 2.3
done
sleep 1

ov on; sleep 2.5
grim -g "$STRIP" $OUT/$TAG-0-before.png
# A second idle capture: separates "the pill did not move" from "the output
# handed back a stale frame", which on this guest is a real failure mode.
sleep 1.0
grim -g "$STRIP" $OUT/$TAG-1-idle.png

# An open/close cycle on its own must not move the pill either, or the "after"
# capture below could not tell a minimize from a reopen.
ov off; sleep 1.2; ov on; sleep 2.5
grim -g "$STRIP" $OUT/$TAG-2-cycle.png

# The minimize has to happen with the overview CLOSED: the dispatcher acts on
# the focused window, and while the overview is up IT owns the focus, so a
# minimize issued here silently does nothing. The first cut of this rig did
# exactly that and "passed" against a dock that never saw a minimized window.
ov off; sleep 1.2
A=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='X46A'), ''))")
[ -n "$A" ] || { echo "ABORT: no X46A window"; exit 1; }
dsp "hl.dsp.focus({ window = [[address:$A]] })"; sleep 0.6
dsp "hl.plugin.$RIG_NS.minimize([[window]])"; sleep 1.5

N=$(minimized_total)
echo "minimized now: $N"
# A rig that cannot fail is not a rig: if nothing minimized there is nothing to
# measure and this must be an ABORT, never a pass.
[ "$N" = "1" ] || { echo "ABORT: expected exactly 1 minimized window, got $N"; exit 1; }

ov on; sleep 2.5
grim -g "$STRIP" $OUT/$TAG-3-after.png

ov off
echo X46_RIG_DONE
