#!/usr/bin/env bash
# Y4 follow-up: does CTRL+click actually STEP through the app's windows?
# The first probe showed ctrl+click correctly minimized nothing, but focus
# stayed on THREE -- which is what a cycle landing on the already-focused
# window looks like, and also what a dead cycle looks like. Three clicks in a
# row tell them apart: a live cycle visits a different window at least twice.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
click() {
    local x=$1 y=$2
    warp $x $y; sleep 0.25
    ydotool key 29:1 >/dev/null 2>&1
    ydotool click 0x40 >/dev/null 2>&1
    sleep 0.06; warp $((x+4)) $((y+3)); sleep 0.06
    ydotool click 0x80 >/dev/null 2>&1
    ydotool key 29:0 >/dev/null 2>&1
    sleep 1.0
}
focused() { hyprctl activewindow -j | python3 -c "
import json,sys
print(json.load(sys.stdin).get('title','(none)'))" 2>/dev/null; }

# The dock must hold RUNNING CLASSES ONLY, or x47_cell.py's prediction aims at
# the wrong icon -- the first run of this probe clicked Nautilus, whose window is
# titled "Home", and read that as a broken cycle.
cfg_dock "autohide=false, show_favorites=false, show_apps_button=false, show_trash=false, show_mounts=false"
sleep 0.8
trap 'cfg_dock "autohide=true, show_favorites=true, show_apps_button=true, show_trash=true"' EXIT

echo "windows: $(hyprctl clients -j | python3 -c "
import json,sys
print(' '.join(sorted(c['title'] for c in json.load(sys.stdin) if c['class']=='Y4A')))")"

# ONE icon in the pill, so a mis-aimed click cannot silently hit another app.
# The first run clicked Nautilus for exactly this reason.
pkill -f nautilus >/dev/null 2>&1; sleep 1.5

hyprctl eval "return hl.dispatch(hl.plugin.$RIG_NS.overview([[on]]))" >/dev/null 2>&1; sleep 2
echo "start focus=$(focused)"
for i in 1 2 3 4; do
    # RE-AIM EVERY TIME. Reusing a hit target computed before the first click is
    # the standing trap in this project: the pill's contents can reorder under
    # it and every later click then lands on a neighbour.
    read -r AX AY <<< "$(hyprctl clients -j | python3 /mnt/host/x47_cell.py Y4A)"
    click $AX $AY
    hyprctl eval "return hl.dispatch(hl.plugin.$RIG_NS.overview([[on]]))" >/dev/null 2>&1; sleep 0.8
    echo "ctrl+click $i at $AX,$AY -> focus=$(focused)"
done
hyprctl eval "return hl.dispatch(hl.plugin.$RIG_NS.overview([[off]]))" >/dev/null 2>&1
