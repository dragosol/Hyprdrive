#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC §13.12 X48 / DoD 23 -- THE RESULTS OWN THE BOTTOM HALF.
# Runs IN THE GUEST. Grades on the HOST with x48_gate.py.
#
# The claim has three parts and each gets its own locator, because each one
# alone passes on a build that is wrong in a different way:
#
#   PANEL   the selected result row (opaque accent, so it is findable by colour)
#           sits BELOW the half-way line. A panel at the top fails this and
#           nothing else -- it is the headline claim.
#   STRIP   the desktop card's mini does not MOVE when results appear. The old
#           layout pushed the strip down by the whole band; DoD 18 says the
#           strip is fixed chrome.
#   TILES   the window tiles give their space back DOWNWARD: the tile block's
#           top must not descend and its foot must rise. The old layout did the
#           opposite -- it pushed the tiles down and shrank them from the top.
#
# Fixture windows are classed K* ON PURPOSE: the query is "k", so they all still
# match it and the grid's MEMBERSHIP does not change between the two frames.
# A fixture that gets filtered out would move the tiles for a reason that has
# nothing to do with the band, and the TILES check would be measuring that.
# Both live on workspace 1 so no cross-desktop promotion can add a third tile.
set -u
source "$(dirname "$0")/lib/rig.sh"   # env discovery, ov/dsp/key, K_* keycodes
rig_env || exit 1
OUT=/mnt/host/x48; mkdir -p $OUT

# TAB, not DOWN: DOWN goes to moveSelection() and walks the GRID's tile
# selection (scrollOverview.cpp:2413). Only Tab walks the result rows, and only
# a selected row is drawn in opaque accent -- which is the whole locator here.

restore() {
    hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = false})" >/dev/null 2>&1
    hyprwall_resume        # the suite's hold applies here too
}

case "${1:?usage: x48_rig.sh fixture|run <tag>}" in

fixture)
    trap restore EXIT
    # A rotating wallpaper repaints the backdrop mid-run, and every check here
    # is a frame diff.
    hyprwall_pause         # a stop under a suite, a dead-man on its own
    ov off; sleep 1
    pkill -x kitty 2>/dev/null; sleep 1.5

    hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = false})" >/dev/null 2>&1; sleep 1.2
    for m in $(hyprctl monitors all -j | python3 -c "
import json,sys
print(' '.join(m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')))"); do
        hyprctl output remove "$m" >/dev/null 2>&1; sleep 0.4
    done
    sleep 1
    hyprctl output create headless >/dev/null 2>&1; sleep 1.5
    MON=$(hyprctl monitors -j | python3 -c "
import json,sys
hs=[m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')]
print(hs[0] if len(hs)==1 else '')")
    [ -n "$MON" ] || { echo "ABORT: expected exactly one headless output"; exit 1; }
    # SET THE MODE. `output create headless` comes up at the headless default
    # 1920x1080, and this fixture is shared by x48, g5 and x50 -- all three of
    # which predict cell/row/pill geometry with predictors that hardcode the
    # guest's 2560x1600 (x24_cell.py, x32_cell.py, x47_cell.py). Until
    # 2026-08-12 this block created the output and never set its mode, so the
    # three gates measured a 1920x1080 screen against 2560x1600 predictions.
    # headless_on does this; this block hand-rolls the output because
    # headless_on installs an EXIT trap that would tear it down when the
    # fixture script exits -- so it must hand-roll the mode too.
    #
    # Virtual-1 goes DOWN FIRST, and that order is not cosmetic: putting the
    # headless output at 0x0 while Virtual-1 is still enabled there makes the
    # two overlap, and Hyprland raises a "Monitor HEADLESS-N overlaps with other
    # monitor(s)" notification that sits in the top right of the frame for the
    # next ~15 seconds -- i.e. across a0 but not across b, which is a change in
    # every frame diff this fixture feeds.
    hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = true})" >/dev/null 2>&1; sleep 1.5
    hyprctl eval "return hl.monitor({output = [[$MON]], mode = [[$RIG_HEADLESS_MODE]], position = [[0x0]], scale = 1})" >/dev/null 2>&1; sleep 1.5
    read -r GOT_W GOT_H <<< "$(hyprctl monitors -j | python3 -c "
import json,sys
m=json.load(sys.stdin)[0]; print(m['width'], m['height'])")"
    WANT_W=${RIG_HEADLESS_MODE%%x*}; WANT_REST=${RIG_HEADLESS_MODE#*x}; WANT_H=${WANT_REST%%@*}
    [ "$GOT_W" = "$WANT_W" ] && [ "$GOT_H" = "$WANT_H" ] \
        || { echo "ABORT: headless came up ${GOT_W}x${GOT_H}, not ${WANT_W}x${WANT_H}"; exit 1; }
    printf '%s\n' "$MON" > $OUT/mon
    hyprctl monitors -j > $OUT/monitors.json
    # BOTH colours the plugin's highlightColor() chooses between, so the graders
    # can mirror that choice instead of hardcoding a hex that matugen re-derives
    # every time the wallpaper changes (Config.hpp X56 block).
    hyprctl getoption general:col.active_border -j > $OUT/accent.json
    hyprctl getoption $RIG_KEY:col_highlight -j    > $OUT/highlight.json

    # kitty, never foot: foot has no per-window opaque switch and a translucent
    # fixture makes every colour mask ambiguous.
    spawn() { # class colour
        dsp "hl.dsp.focus({monitor = \"$MON\"})"; sleep 0.15
        dsp "hl.dsp.focus({workspace = 1})"; sleep 0.2
        setsid kitty -c NONE --class "$1" -T "$1" -o background="$2" -o background_opacity=1.0 \
            -o confirm_os_window_close=0 --hold sh -c 'clear' >/dev/null 2>&1 </dev/null &
        sleep 2.2
        hyprctl clients -j | grep -q "\"$1\"" || { echo "ABORT: $1 did not appear"; exit 1; }
    }
    spawn KRED '#ff0000'
    spawn KBLU '#0000ff'
    dsp 'hl.dsp.focus({workspace = 1})'; sleep 1.0

    hyprctl clients -j > $OUT/fixture-clients.json
    trap - EXIT              # the fixture must SURVIVE for the run phase
    hyprwall_pause         # a stop under a suite, a dead-man on its own
    echo "output: $MON"
    echo X48_FIXTURE_OK
    ;;

run)
    TAG=${2:?usage: x48_rig.sh run <tag>}
    MON=$(cat $OUT/mon)
    shot() { grim -o "$MON" "$OUT/$TAG-$1.png"; }

    ov off; sleep 1.0
    ov on;  sleep 2.5

    # a0/a1 bracket the resting state: identical to each other or the output is
    # drifting and no later diff means anything.
    shot 00-a0; sleep 1.2; shot 01-a1

    key $K_K;    sleep 1.8      # query "k" -- matches both fixtures AND apps
    key $K_TAB;  sleep 1.2      # selection -1 -> 0: row 0 goes opaque accent
    shot 20-b

    key $K_ESC;  sleep 1.8      # clear the query; the band eases shut again
    shot 30-c
    ov off

    ls -la $OUT/$TAG-*.png
    echo X48_RUN_OK
    ;;
esac
