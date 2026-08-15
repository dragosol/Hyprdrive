#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC 13.12 X47: hovering a dock icon raises a LIVE preview panel.
# Runs IN THE GUEST. Captures only -- the analysis is on the HOST (no numpy here).
#
# The claim has four parts and the rig captures a frame for each:
#   RISES     a plate appears above the pill that was not there before
#   LIVE      its contents CHANGE between two frames (a still would pass a
#             one-frame test, and a still preview is the defect X25/X47 name)
#   FOLLOWS   moving to another icon moves the plate rather than dropping it
#   GRACE     leaving the icon does NOT dismiss it immediately
#
# CONTROLS ON BOTH SIDES. The guest's wallpaper drifts and the panel is frosted,
# so a plain "does this frame differ" gate is worthless. Two unhovered frames are
# captured BEFORE the hover and one AFTER, and the gate builds its noise mask
# from those -- if the panel never left, c2 is contaminated and the gate says so.
#
# The dock's autohide is turned OFF for the run and restored at the end: the
# pressure barrier needs sustained relative motion and a ydotool warp is one
# jump, so a rig that relied on it would be testing the barrier, not the panel.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1

TAG=${1:?usage: x47_rig.sh <tag>}
OUT=/mnt/host/x47; mkdir -p $OUT

# dsp()/ov()/warp()/cfg_dock() come from lib/rig.sh (identical bodies lived
# here first; warp owns the ydotool halving).

# RESTORE ON EVERY EXIT PATH, including the aborts below. An earlier run of this
# rig exited through one of those aborts and left the guest on a headless output
# with Virtual-1 disabled -- so the VM's actual screen was blank, and the next
# thing to re-enable Virtual-1 put two outputs at 0x0 and Hyprland's "monitor
# layout is set up incorrectly, HEADLESS-1 overlaps" banner came up. A rig that
# swaps the display out is only safe if the swap back cannot be skipped.
restore() {
    ov off
    cfg_dock "autohide=true, show_favorites=true, show_apps_button=true, show_trash=true, show_mounts=false"
    # Back to Config.cpp's declared defaults. A frost arm that left blur_size=20
    # behind would silently re-tune the user's dock for every later run.
    cfg_dock "blur_size=7, blur_passes=3"
    # Virtual-1 comes back FIRST, then the headless goes away: rig.sh
    # headless_off owns that ordering (it was learned here).
    headless_off
    hyprwall_resume
}

# Dead-man resume included (hyprwall_pause), so the desktop is not left frozen
# even if this run dies where no trap fires (SIGKILL, or the compositor going
# down under it).
hyprwall_pause 30min

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5

# HEADLESS OUTPUT, Virtual-1 DISABLED. Virtual-1 draws ~1fps while no viewer is
# attached to the VM, so grim hands back the same stale frame over and over --
# the first run of this rig scored 0 changed pixels between two frames of a
# counter ticking every 80ms, which is that failure and nothing else. rig.sh
# headless_on is this rig's own block, promoted; the mode stays at the @60 this
# rig was proved at.
RIG_HEADLESS_MODE=2560x1600@60
headless_on || exit 1
# headless_on installed `trap headless_off EXIT`; CHAIN the rest of x47's
# cleanup so an abort restores as thoroughly as a clean finish does.
trap restore EXIT

MON=$RIG_MON W=$RIG_W H=$RIG_H
echo "monitor: $MON ${W}x${H}"

# `hyprctl keyword` is DEAD in 0.56 -- every call answers "can't work with
# non-legacy parsers" on stderr and returns 0, so a rig that used it configured
# nothing and said nothing. Config goes through cfg_dock() (hl.config), and
# want() reads the value back (rig.sh opt_want) to prove it landed.
want() { opt_want "$RIG_KEY:dock:$1" "$2" || { echo "ABORT: dock:$1 readback failed"; exit 1; }; }

# THE DOCK HOLDS RUNNING CLASSES AND NOTHING ELSE for this run. x47_cell.py
# predicts icon centres from the class list, and a rig that had to model the
# favourites file, the .desktop lookups behind it and the Locations items would
# be a second implementation of dockItems() -- which is the thing most likely to
# drift out of step with the one under test. Switching the other sources OFF is
# what keeps the prediction a prediction rather than a read-back.
cfg_dock "autohide=false, show_favorites=false, show_apps_button=false, show_trash=false, show_mounts=false"
sleep 0.8
for k in autohide show_favorites show_apps_button show_trash show_mounts; do want $k false; done

# X47_BLUR: the FROST A/B drives the panel's blur through the SAME runtime keys
# renderHoverPreview() reads per frame (Dock.cpp:2628). Read back, because a
# config that silently did not land would make the two arms identical and the
# frost gate would report "no difference" as a product failure.
#   e.g. X47_BLUR='blur_size=1, blur_passes=1'   (sharp arm)
#        X47_BLUR='blur_size=20, blur_passes=4'  (frosted arm)
if [ -n "${X47_BLUR:-}" ]; then
    cfg_dock "$X47_BLUR"
    sleep 0.5
    # NOT a `... | while read`: that runs in a subshell, so want()'s abort would
    # exit the pipeline and the rig would sail on with unverified config. And NOT
    # `IFS=, ; for kv in $X47_BLUR`: want()'s own `read -r VAL SET` inherits that
    # IFS and stops splitting on whitespace, so it compares "1 true " against "1"
    # and every arm aborts. Commas become spaces instead; no kv contains one.
    for kv in $(echo "$X47_BLUR" | tr ',' ' '); do want "${kv%%=*}" "${kv##*=}"; done
    echo "blur: $X47_BLUR"
fi

# THREE windows of one class, so the panel has to lay out three cells side by
# side -- one cell would pass on code that ignores the count entirely.
# The FIRST one prints a fast counter: that is the only thing in this fixture
# that changes on its own, so it is the whole of the LIVE signal.
# The counter FILLS the window rather than printing one line in the corner. A
# preview cell is the window scaled down ~5x, and a single line of digits
# survives that as three changed pixels -- measured, and it is under any honest
# threshold, so a live preview and a frozen one were indistinguishable. Forty
# rows of changing digits are still changing after the downscale.
setsid kitty -c NONE --class X47A -o background='#101820' -o background_opacity=1.0 \
    -o font_size=40 -o confirm_os_window_close=0 \
    --hold sh -c 'while :; do s=$(date +%s.%N); printf "\033[H\033[2J"; i=0; while [ $i -lt 40 ]; do printf "%s %d\n" "$s" "$i"; i=$((i+1)); done; sleep 0.08; done' >/dev/null 2>&1 </dev/null &
sleep 2.4
# X47_STRIPES: fill the non-counter fixtures with static high-contrast stripes
# instead of leaving them blank. The FROST A/B needs TEXTURE BEHIND THE PLATE,
# and the plate's backdrop in this band is the desktop-strip minis of these very
# windows -- measured: with blank fixtures the band's two control frames are
# BYTE-IDENTICAL, so a blur of any radius over them is a no-op and a blur_size
# A/B could not fail. Static, not ticking: LIVE must stay the counter's alone.
# X47_STRIPES: fill the non-counter fixtures with static high-contrast stripes
# instead of leaving them blank. The FROST A/B needs TEXTURE BEHIND THE PLATE,
# and the plate's backdrop in this band is the desktop-strip minis of these very
# windows -- measured: with blank fixtures the band's two control frames are
# BYTE-IDENTICAL, so a blur of any radius over them is a no-op and a blur_size
# A/B could not fail. Static, not ticking: LIVE must stay the counter's alone.
#
# STILL NOT ENOUGH, and not fixed here (ticket: x47_frost_texture.md). One-row
# stripes measure HF-y 1.02 behind the plate against the gate's own >2.0
# precondition. Coarsening them to five-row bands was tried on 2026-08-12 and
# measured WORSE, not better -- HF-y 0.50 and luminance sd 9.0 where the fine
# stripes give sd 96.0 -- so the backdrop the plate is over is not simply a
# downscale of this pattern and the calibration needs the band identified
# before the fixture is chosen again.
FILL='clear'
[ "${X47_STRIPES:-0}" = 1 ] && FILL='i=0; while [ $i -lt 40 ]; do
    if [ $((i%2)) = 0 ]; then printf "\033[107m%*s\033[0m\n" 200 ""
    else printf "\033[40m%*s\033[0m\n" 200 ""; fi; i=$((i+1)); done; sleep infinity'
for i in 1 2; do
    setsid kitty -c NONE --class X47A -o background='#101820' -o background_opacity=1.0 \
        -o confirm_os_window_close=0 --hold sh -c "$FILL" >/dev/null 2>&1 </dev/null &
    sleep 2.2
done
# A second class, so FOLLOWS has somewhere to travel to.
setsid kitty -c NONE --class X47B -o background='#302010' -o background_opacity=1.0 \
    -o confirm_os_window_close=0 --hold sh -c "$FILL" >/dev/null 2>&1 </dev/null &
sleep 2.4

N=$(hyprctl clients -j | python3 -c "
import json,sys
print(sum(1 for c in json.load(sys.stdin) if c['class']=='X47A'))")
[ "$N" = "3" ] || { echo "ABORT: expected 3 X47A windows, got $N"; exit 1; }
hyprctl clients -j > $OUT/$TAG-clients.json

# The predictor comes from THIS tree, so the Dock.cpp constants under test and
# the ones predicting from them cannot drift apart via a stale share copy.
CELL=$RIG_LIB_DIR/../x47_cell.py
read -r AX AY <<< "$(hyprctl clients -j | python3 "$CELL" X47A)"
read -r BX BY <<< "$(hyprctl clients -j | python3 "$CELL" X47B)"
read -r PX PY PW PH <<< "$(hyprctl clients -j | python3 "$CELL" panel)"
echo "icon X47A=$AX,$AY  X47B=$BX,$BY   predicted panel=$PX,$PY ${PW}x${PH}"
echo "$PX $PY $PW $PH" > $OUT/$TAG-panel.txt

# The band is the panel's own rows and nothing else. It deliberately STOPS short
# of the pill's top edge: the hover highlight lights up inside the pill on every
# hover, and counting that as panel signal would make this gate unfailable.
BAND="0,$((PY - 24)) ${W}x$((PH + 24))"
echo "band: $BAND"
shot() { grim -g "$BAND" "$OUT/$TAG-$1.png" 2>/dev/null; }

PARKX=$((W - 60)); PARKY=60

# THE DOCK IS DRAWN BY THE OVERVIEW PASS, so there is no dock to hover with the
# overview closed -- the first run of this rig hovered an empty desktop and got
# seven identical frames of wallpaper, which reads exactly like a dead capture
# pipeline and is not one. Same `ov on` x45dock_rig.sh opens with.
ov on; sleep 2.5

# --- controls before -------------------------------------------------------
warp $PARKX $PARKY; sleep 1.5
shot c0
sleep 0.7
shot c1

# PIPELINE LIVENESS, whole screen, deliberately NOT the band. The counter window
# ticks every 80ms, so two full-screen grabs 0.5s apart must differ no matter
# what the dock does; if they do not, grim is handing back a stale frame and
# every "nothing changed" below means nothing. It cannot be the band's own
# frames: with no panel up the band is idle wallpaper, and two identical control
# frames are what a HEALTHY run looks like there. rig.sh pipeline_live_or_die
# also fails IN-GUEST on identical frames; the p0/p1 frames stay on disk for the
# gate's own FRESH check.
pipeline_live_or_die "$OUT" "$TAG"

# --- RISES + LIVE ----------------------------------------------------------
# The pointer is where the rig THINKS it is, or nothing below means anything
# (warp_or_die). Every silent failure this project has recorded around input
# started with a warp that did not land where the rig aimed it.
warp_or_die $AX $AY
sleep 0.5            # past PANEL_IN_MS (170) with room to spare
shot h0
sleep 0.5            # the counter ticks every 80ms, so this must differ
shot h1

# --- FOLLOWS ---------------------------------------------------------------
warp $BX $BY
sleep 0.9
shot t0

# --- GRACE -----------------------------------------------------------------
# 120ms after leaving, which is inside PANEL_GRACE_MS (180): still up.
warp $PARKX $PARKY
sleep 0.12
shot g0

# --- control after ---------------------------------------------------------
sleep 1.6            # grace + PANEL_OUT_MS, with room
shot c2

# --- FROST A/B: A FIXTURE THAT OWNS THE PLATE'S BACKDROP --------------------
# X47_FROST_PAIR=1. This phase used to run inline above, with the overview open,
# and it measured whatever happened to be behind the plate. That was the bug:
# the SAME BUILD gave a backdrop step of 216.5/255 inside a suite and 13.0 in a
# standalone re-run twenty minutes later, because what the plate was frosting
# was the scene the PREVIOUS GATE left on screen. A fixture must own what the
# gate photographs; this one did not own it at all.
#
# Two things are different here, and the probe that settled both is
# zrig/final/x47-fixture/.
#
# THE OVERVIEW IS CLOSED. The rig's old comment said "the dock is drawn by the
# overview pass, so there is no dock to hover with the overview closed". That
# stopped being true when X27 moved the dock to RENDER_POST_WINDOWS, and the
# probe measured it: hovering with the overview CLOSED raises the plate
# perfectly well (120095 px change over the plate rect). It also has to be
# closed -- with the overview OPEN the plate sits over the workspace-card
# background, which is flat: profile sd 0.9 and a step of 4.0, i.e. nothing to
# blur. Closed, the desktop is behind the plate and we can put something there.
#
# X47Z IS THAT SOMETHING. One extra kitty, solid white, positioned so its BOTTOM
# EDGE falls STEPROW rows into the plate: white above, the compositor's dark
# background below, one hard horizontal step across the whole plate width. That
# is the shape x47_frost.py grades (EDGE = argmax|diff| finds it, TEXTURE wants
# it >40/255 and 6..len-8 rows in) and now the rig placed it instead of hoping
# for it.
#   * A NEW CLASS SHIFTS EVERY ICON, so the predictions are re-read after it is
#     up -- x47_cell.py reads the live client list, so it accounts for the
#     fourth icon on its own. The plate's x is icon_x - width/2 (the grader's
#     own note), which is what centres the backdrop on it.
#   * It is spawned AFTER every behaviour capture, so RISES/LIVE/FOLLOWS/GRACE
#     see exactly the scene they always saw.
#   * It is WIDER than the plate by BACKPAD on each side, so the window's own
#     rounded corners and border are outside every column the grader samples.
#   * It is STATIC. SAMEBACK asserts the two arms share a bit-identical control
#     frame, and the ticking counter stays where it was, far above this band.
if [ "${X47_FROST_PAIR:-0}" = 1 ]; then
    STEPROW=30      # rows into the plate; grader needs the step 6..PH-8 in
    BACKPAD=200     # how far past the plate the backdrop reaches on each side
    BACKH=160       # tall enough to matter, short enough to clear the X47A row

    ov off; sleep 1.5
    warp $PARKX $PARKY; sleep 1.0

    # Spawned first at a provisional rect, because the prediction it has to obey
    # cannot be read until it exists: it is the fourth icon that moves X47A.
    fixture_kitty X47Z 400 1200 600 "$BACKH" '#ffffff' 'clear; sleep infinity' \
        || { echo "ABORT: X47Z backdrop never mapped"; exit 1; }

    read -r AX AY <<< "$(hyprctl clients -j | python3 "$CELL" X47A)"
    read -r PX PY PW PH <<< "$(hyprctl clients -j | python3 "$CELL" panel)"
    PLATEX=$((AX - PW / 2))
    BX0=$((PLATEX - BACKPAD)); BW=$((PW + 2 * BACKPAD))
    BY0=$((PY + STEPROW - BACKH))
    echo "frost: icon X47A=$AX  plate x=$PLATEX ${PW}x${PH} at y=$PY"
    echo "frost: backdrop X47Z ${BW}x${BACKH} at $BX0,$BY0 -- step at plate row $STEPROW"

    hyprctl eval "$(cat <<LUA
for _, w in ipairs(hl.get_windows()) do
    if w.class == "X47Z" then
        hl.dispatch(hl.dsp.focus({window = w}))
        hl.dispatch(hl.dsp.window.resize({x = $BW, y = $BACKH, relative = false}))
        hl.dispatch(hl.dsp.window.move({x = $BX0, y = $BY0, relative = false}))
    end
end
return 1
LUA
)" >/dev/null 2>&1
    sleep 0.9
    # It has to BE where it was put, or the step is not where the grader looks.
    read -r GX GY GW GH <<< "$(hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c['class'] == 'X47Z':
        print(c['at'][0], c['at'][1], c['size'][0], c['size'][1]); break")"
    echo "frost: X47Z landed at $GX,$GY ${GW}x${GH}"
    [ "$((GY + GH))" -ge "$((PY + STEPROW - 6))" ] && [ "$((GY + GH))" -le "$((PY + STEPROW + 6))" ] \
        || { echo "ABORT: X47Z bottom edge at $((GY + GH)), wanted $((PY + STEPROW)) +-6"; exit 1; }

    echo "$PX $PY $PW $PH" | tee $OUT/frost-fa-panel.txt > $OUT/frost-fb-panel.txt

    # Control FIRST and unhovered: it is the backdrop profile the whole gate is
    # graded against. One capture, shared by both arms, so SAMEBACK is exact.
    sleep 0.8
    grim -g "$BAND" $OUT/frost-fa-c0.png 2>/dev/null
    cp $OUT/frost-fa-c0.png $OUT/frost-fb-c0.png

    warp_or_die $AX $AY
    sleep 0.6
    cfg_dock "blur_size=20, blur_passes=4"; sleep 0.6
    for kv in blur_size=20 blur_passes=4; do want "${kv%%=*}" "${kv##*=}"; done
    grim -g "$BAND" $OUT/frost-fb-h0.png 2>/dev/null
    cfg_dock "blur_size=1, blur_passes=1"; sleep 0.6
    for kv in blur_size=1 blur_passes=1; do want "${kv%%=*}" "${kv##*=}"; done
    grim -g "$BAND" $OUT/frost-fa-h0.png 2>/dev/null
    warp $PARKX $PARKY
    echo "frost pair: frost-fa (sharp) + frost-fb (frosted) over one frozen hover, own backdrop"
fi

# The overview, the dock config and the DISPLAY all go back in restore(), on the
# EXIT trap, so an abort restores as thoroughly as a clean finish does.
echo "frames: $(ls $OUT/$TAG-*.png | wc -l)"
echo X47_RIG_OK
