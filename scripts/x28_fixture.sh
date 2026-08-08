#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC 13.9 X28 fixture. Runs IN THE GUEST.
#
# Two dock classes with different capabilities, because the menu's content
# depends on whether a desktop entry claims the class:
#   kitty     -- a real entry, so it has an id: Show Details and the favourites
#                toggle have something to act on.
#   X28QUIT   -- two windows of a synthetic class nothing claims, so Quit can be
#                fired at it without taking the favourites fixture down too.
#
# Headless output, Virtual-1 disabled: Virtual-1 draws ~1fps with no viewer
# attached and every capture in this rig would be a stale frame.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
OUT=/mnt/host/x28; mkdir -p $OUT

hyprwall_pause

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5

# Headless create + Virtual-1 disable moved to rig.sh headless_on, called by
# the WRAPPER (scripts/gates/x28/run.sh): headless_on installs an EXIT-trap
# teardown, and from here it would fire when this fixture exits -- before a
# single click. The wrapper's process spans the whole gate, so the swap-back
# happens after the last frame instead.
[ -n "${RIG_MON:-}" ] || { echo "ABORT: RIG_MON unset -- run via scripts/gates/x28/run.sh (headless_on first)"; exit 1; }
MON=$RIG_MON

hyprctl monitors -j | python3 -c "
import json,sys
m=json.load(sys.stdin)[0]; print('MON %s %d %d' % (m['name'], m['width'], m['height']))" > $OUT/monitor.txt
cat $OUT/monitor.txt

# The favourites store starts empty, or the toggle's direction is unknowable.
rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/scrolloverview/favorites"

spawn() { # class
    dsp "hl.dsp.focus({monitor = \"$MON\"})"; sleep 0.15
    if [ "$1" = kitty ]; then
        setsid kitty -c NONE -o background='#202030' -o background_opacity=1.0 \
            -o confirm_os_window_close=0 --hold sh -c 'clear' >/dev/null 2>&1 </dev/null &
    else
        setsid kitty -c NONE --class "$1" -o background='#303020' -o background_opacity=1.0 \
            -o confirm_os_window_close=0 --hold sh -c 'clear' >/dev/null 2>&1 </dev/null &
    fi
    sleep 2.2
}

spawn kitty
spawn X28QUIT
spawn X28QUIT

sleep 1.5
hyprctl clients -j > $OUT/fixture-clients.json
python3 -c "
import json
for c in json.load(open('$OUT/fixture-clients.json')):
    if c['class'] in ('kitty','X28QUIT'):
        print(' ', c['class'], c['address'], c['workspace']['name'])
"

ov off; sleep 1.2
ov on;  sleep 3
grim -o $MON $OUT/base.png
echo X28_FIXTURE_OK
