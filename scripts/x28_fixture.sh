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

# P4 toggles kitty's favourites row twice and reads the store between the two
# clicks, so it has to KNOW which way the first click goes -- and that means
# kitty must not already be a favourite when it starts.
#
# Deleting the store used to arrange that by accident: the dock read the file
# once at PLUGIN_INIT and never again, so a deletion could not reach the running
# session and whatever the dock held at start-up (never kitty) was what the row
# read. The store is live now (404b513), and a deletion means "the file is gone",
# not "there are no favourites" -- the dock deliberately keeps what it had rather
# than re-seeding under the user. So the first click landed on `Remove from
# Favorites` instead of `Add`, the two reads came back one step out of phase,
# and P4 reported a working toggle as `the row toggled []`.
#
# The precondition is now WRITTEN instead of wished for: a store the dock will
# actually adopt, holding two ids that are not the app under test.
mkdir -p "$(dirname "$RIG_FAV")"
# No settle here on purpose: the store is polled at most twice a second and the
# spawns below take seconds, so the dock has adopted it long before anything is
# photographed -- and a settle HERE shifts every capture in the run by a second,
# which walked P2's blinking-cursor residual straight over its own floor.
printf 'org.gnome.Nautilus\norg.gnome.Calculator\n' > "$RIG_FAV"

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

# The dock the CELL PREDICTORS model: running classes and nothing else.
# x24_cell.py / x28_cell.py compute slot centres from the class list alone, and
# gate_slate leaves favourites, the Show Applications button and the trash ON --
# five slots where the predictor counts two. Measured 2026-08-12: the pill is
# then 362px wide at x1099 instead of 152px at x1204, and the click the rig
# believed was on the fixture's icon landed on the TRASH. gate_slate puts all of
# these back before the next gate, so turning them off here costs nothing.
cfg_dock "show_favorites=false, show_apps_button=false, show_trash=false, show_mounts=false"
sleep 0.6
opt_want $RIG_KEY:dock:show_apps_button false || { echo "ABORT: dock composition did not take"; exit 1; }

ov off; sleep 1.2
ov on;  sleep 3
grim -o $MON $OUT/base.png
echo X28_FIXTURE_OK
