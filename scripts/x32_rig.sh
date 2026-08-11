#!/usr/bin/env bash
# X32 Show Applications -- A FRESH OPEN FROM THE DOCK STARTS CLEAN.
# Runs IN THE GUEST; graded by x32_gate.py on the same frames.
#
# The defect (orchestrator, 2026-08-11): the dock's Show Applications button
# calls openScrollOverview() -> openOverview() directly, so it skips the reset
# the dispatcher does before every open. Type a query, close the overview
# WITHOUT going through the dispatcher, press the button -- and the overview
# comes back still filtered by the query nobody typed this time.
#
# "WITHOUT going through the dispatcher" is the whole design of this rig and the
# reason it does not simply `ov off`: `overview off` IS the dispatcher, and the
# dispatcher's first line is the reset. Closing that way would clear the query
# itself and the rig would pass on the broken build. So the close is a TILE
# CLICK -- the user's own path, CScrollOverview::close(), which resets nothing.
#
# Four frames, and each one is only meaningful next to the others:
#   c0/c1  a clean dispatcher-opened overview, twice -- this run's noise floor
#   q      the same overview with a query typed -- MUST differ from c0, or the
#          keystroke never landed and everything below is measuring nothing
#   d      opened by the BUTTON after that query was closed away -- must be
#          back at c0 and nowhere near q
#
# The fixture is ONE flat magenta window because the tile click needs a target
# the grader can find honestly: the largest connected blob of fixture colour in
# the open overview, never a bounding box (standing pixel doctrine).
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
OUT=/mnt/host/x32; mkdir -p $OUT

TAG=${1:?usage: x32_rig.sh <tag>}
FIX=X32FIX
QUERY_KEY=$K_X          # "x" -- matches X32FIX, so the fixture tile SURVIVES the
                        # filter and stays clickable; a no-match query would hide
                        # the very tile the close depends on.

restore() {
    ov off
    cfg_dock "autohide=true, show_favorites=true, show_apps_button=true, show_trash=true, show_mounts=false"
    headless_off
    hyprwall_resume
}
trap restore EXIT

hyprwall_pause
ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5

headless_on || exit 1
trap restore EXIT       # re-chain: headless_on installed its own EXIT trap

MON=$RIG_MON W=$RIG_W H=$RIG_H
echo "monitor: $MON ${W}x${H}"

# The button must be ON (it is the thing under test) and the dock must be
# parked visible, or the click has nothing to hit. Everything else off so the
# cell prediction has as few slots as possible to be wrong about.
cfg_dock "autohide=false, show_favorites=false, show_apps_button=true, show_trash=false, show_mounts=false"
sleep 0.8
opt_want plugin:scrolloverview:dock:show_apps_button true || { echo "ABORT: show_apps_button did not take"; exit 1; }
opt_want plugin:scrolloverview:dock:autohide         false || { echo "ABORT: autohide did not take"; exit 1; }

dsp "hl.dsp.focus({monitor = \"$MON\"})"; sleep 0.3
dsp "hl.dsp.focus({workspace = 1})"; sleep 0.4
fixture_kitty $FIX 300 200 1600 1000 '#ff00ff' || { echo "ABORT: fixture did not come up"; exit 1; }
dsp "hl.dsp.focus({workspace = 1})"; sleep 0.8

read -r SAX SAY <<< "$(hyprctl clients -j | python3 "$(dirname "$0")/x32_cell.py" showapps)"
[ -n "${SAX:-}" ] || { echo "ABORT: no Show Applications cell predicted"; exit 1; }
echo "showapps cell $SAX,$SAY"

# Every frame is taken with the pointer PARKED in the same place, and parked
# long enough for the hover it left to finish easing out. Frame d is captured
# right after a click on the Show Applications button, so without the park the
# button would still be lit and tooltipped in d and in no other frame -- a
# difference that has nothing to do with the query, sitting right in the middle
# of the CLEAN measurement.
#
# park() is separate from shot() on purpose: parking INSIDE the capture put the
# move between c0 and c1 and the ease-out landed between them, which took this
# run's noise floor from 178 px to 114761 and made every threshold derived from
# it meaningless.
# The park point is MEASURED, not chosen: four candidates, four idle frames
# each, pick one where consecutive frames do not move. The obvious top-right
# corner y11 uses is the worst of them here -- something in the bar's right end
# expands about a second and a half after the pointer arrives and put 50921
# changed pixels between the two control frames, i.e. a noise floor bigger than
# the effect. The left edge at mid-height is quiet (5 / 0 / 87 px over three
# intervals) and is outside the fixture tile's own box.
PARKX=60; PARKY=$((H / 2))
park() { warp $PARKX $PARKY; sleep 2.4; }
shot() { grim -o "$MON" "$OUT/$TAG-$1.png"; }

# The tile click target: the largest connected blob of fixture magenta in the
# OPEN overview, computed by the grader off c0 so the rig and the verdict agree
# about where the tile is.
tile_click() {
    local pt
    pt=$(python3 "$(dirname "$0")/x32_gate.py" --tile "$OUT/$TAG-c0.png") || return 1
    echo "tile at $pt"
    # shellcheck disable=SC2086
    click $pt
    sleep 1.6
}

# ---- c0/c1: a clean open, twice ------------------------------------------
ov off; sleep 1.0
ov on;  sleep 4.0        # the open has to be FINISHED, not nearly: c0 taken at
park                     # 2.5s left 48043 px of it still moving into c1
sleep 1.5
shot c0; sleep 1.2; shot c1

tile_click || { echo "ABORT: could not find the fixture tile in the open overview"; exit 1; }
alive_or_die "after the first tile click"

# ---- q: the same overview with a query typed -----------------------------
ov on;  sleep 2.5
park                            # typed with the pointer where c0 had it
key $QUERY_KEY
sleep 3.0                       # G7 debounce, then the providers' round trip
shot q

# Close the way a USER closes it: a tile click. Not `ov off` -- that is the
# dispatcher and it would do the reset this gate exists to test for.
tile_click || { echo "ABORT: the queried overview had no clickable tile"; exit 1; }
alive_or_die "after the queried tile click"

# ---- d: opened by the button ---------------------------------------------
warp_or_die "$SAX" "$SAY"
sleep 0.4
click "$SAX" "$SAY"
sleep 2.8
park
shot d

ov off; sleep 1.0
ls -la $OUT/$TAG-*.png
echo X32_RIG_OK
