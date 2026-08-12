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
# BAND WIDTH IS THE CALIBRATION. The plate's backdrop is the desktop-strip MINI
# of this window, not the window: a ~900px-tall fixture is drawn into ~130px of
# panel, so a stripe pattern that alternates every ROW arrives as flat grey.
# Measured 2026-08-12 on 7b32fd6 with one-row stripes: the backdrop behind the
# plate scored HF-y 1.02 against the gate's own >2.0 precondition, so TEXTURE
# failed and BLURS was grading a smear of nothing -- which is exactly what
# TEXTURE exists to catch. Five-row bands survive the same downscale at roughly
# 15px each. Static, not ticking: LIVE must stay the counter's alone.
FILL='clear'
[ "${X47_STRIPES:-0}" = 1 ] && FILL='i=0; while [ $i -lt 40 ]; do
    if [ $(( (i/5) % 2 )) = 0 ]; then printf "\033[107m%*s\033[0m\n" 200 ""
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

# --- FROST A/B, both configs against THIS ONE frozen hover ------------------
# X47_FROST_PAIR=1: the frost gate needs a sharp plate and a frosted plate over
# a BIT-IDENTICAL backdrop, differing only in the blur pass. Two separate rig
# runs cannot give that -- the striped fixtures float to slightly different
# spots each run, so the plate's backdrop moves and SAMEBACK (its control) fails
# with the plate rect half off the fixture. So capture BOTH here, still hovering
# X47A, changing nothing but dock:blur_size/passes (renderHoverPreview reads
# them per frame, Dock.cpp). The control frame carries no panel, so it is
# blur-independent -- fa-c0 and fb-c0 are the same desktop and are shared.
if [ "${X47_FROST_PAIR:-0}" = 1 ]; then
    echo "$PX $PY $PW $PH" | tee $OUT/frost-fa-panel.txt > $OUT/frost-fb-panel.txt
    cp $OUT/$TAG-c0.png $OUT/frost-fa-c0.png
    cp $OUT/$TAG-c0.png $OUT/frost-fb-c0.png
    cfg_dock "blur_size=20, blur_passes=4"; sleep 0.6
    for kv in blur_size=20 blur_passes=4; do want "${kv%%=*}" "${kv##*=}"; done
    grim -g "$BAND" $OUT/frost-fb-h0.png 2>/dev/null
    cfg_dock "blur_size=1, blur_passes=1"; sleep 0.6
    for kv in blur_size=1 blur_passes=1; do want "${kv%%=*}" "${kv##*=}"; done
    grim -g "$BAND" $OUT/frost-fa-h0.png 2>/dev/null
    cfg_dock "blur_size=20, blur_passes=4"; sleep 0.4   # main run stays frosted
    echo "frost pair: frost-fa (sharp) + frost-fb (frosted) over one hover"
fi

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

# The overview, the dock config and the DISPLAY all go back in restore(), on the
# EXIT trap, so an abort restores as thoroughly as a clean finish does.
echo "frames: $(ls $OUT/$TAG-*.png | wc -l)"
echo X47_RIG_OK
