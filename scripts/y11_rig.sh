#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC §13.14 Y11 — THE REGRESSION GATE ON X99.
#
# User, 2026-08-06: "make sure dock previews render windows from other desktops
# properly - grok seems to have caused a regression there". The spec is explicit
# that Y11 "is not closed by reading X99's commit message, it is closed by a
# measurement showing a non-active-desktop window's preview is live and
# non-blank."
#
# So there are two claims and they need different evidence:
#
#   NON-BLANK  the cell contains the window, not a hole. A colour count.
#   LIVE       the cell CHANGES between two frames. A still preview passes any
#              one-frame test, and a frozen preview is the exact defect X25 and
#              X47 both name.
#
# The fixture prints a nanosecond clock across FORTY ROWS rather than one line:
# a preview cell is the window scaled down ~8x, and a single line of digits
# survives that as a handful of pixels, which is under any honest threshold --
# measured by X47, which is why it says so in its own header.
#
# The desktop is swapped back and forth BEFORE the measurement, deliberately.
# That was Z1's bug (a parked workspace's m_renderOffset put the preview a
# monitor away), so a Y11 gate that skipped it would pass on the one state the
# user does not have.
#
# CONTROLS: two unhovered frames, so the "live" number has a noise floor taken
# from this wallpaper on this run rather than from a remembered one.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1

TAG=${1:?usage: y11_rig.sh <tag>}
OUT=/mnt/host/y11; mkdir -p $OUT

WS_HOME=1
WS_AWAY=7

restore() {
    ov off
    cfg_dock "autohide=true, show_favorites=true, show_apps_button=true, show_trash=true, show_mounts=false"
    dsp "hl.dsp.focus({workspace = $WS_HOME})"
    headless_off
    hyprwall_resume
}
trap restore EXIT

hyprwall_pause

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5
dsp "hl.dsp.focus({workspace = $WS_HOME})"; sleep 0.8

RIG_HEADLESS_MODE=2560x1600@60      # this gate was proven at @60 [rig.sh header note]
headless_on || exit 1
trap restore EXIT                   # re-chain: headless_on installed its own EXIT trap

MON=$RIG_MON W=$RIG_W H=$RIG_H
echo "monitor: $MON ${W}x${H}"

cfg_dock "autohide=false, show_favorites=false, show_apps_button=false, show_trash=false, show_mounts=false"
sleep 0.8

# Magenta ground, black digits: the background is the NON-BLANK signal and the
# digits are the LIVE one, so one fixture answers both without either masking
# the other.
dsp "hl.dsp.focus({monitor = \"$MON\"})"; sleep 0.3
dsp "hl.dsp.focus({workspace = $WS_HOME})"; sleep 0.4
setsid kitty -c NONE --class Y11A --title Y11WIN -o background='#ff00ff' -o foreground='#000000' \
    -o background_opacity=1.0 -o font_size=40 -o confirm_os_window_close=0 \
    --hold sh -c 'while :; do s=$(date +%s%N); printf "\033[H\033[2J"; i=0; while [ $i -lt 40 ]; do printf "%s %d\n" "$s" "$i"; i=$((i+1)); done; sleep 0.08; done' \
    >/dev/null 2>&1 </dev/null &
sleep 3.5

ADDR=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='Y11A'), ''))")
[ -n "$ADDR" ] || { echo "ABORT: Y11A did not appear"; exit 1; }

# PIPELINE LIVENESS, and it is not optional. The Y11A fixture lives on another
# desktop, so the ONLY place its clock can appear is the preview -- which means
# "nothing changed" is equally consistent with a frozen preview and with a
# capture pipeline handing back the same frame twice. That second failure is the
# one this project has hit repeatedly (15 grabs, 14 identical). Y11B ticks the
# same way ON THE HOME DESKTOP, so it is visible in the overview's main area and
# its pixels must change between any two frames however the preview behaves.
setsid kitty -c NONE --class Y11B --title Y11PROBE -o background='#00ff88' -o foreground='#000000' \
    -o background_opacity=1.0 -o font_size=40 -o confirm_os_window_close=0 \
    --hold sh -c 'while :; do s=$(date +%s%N); printf "\033[H\033[2J"; i=0; while [ $i -lt 40 ]; do printf "%s %d\n" "$s" "$i"; i=$((i+1)); done; sleep 0.08; done' \
    >/dev/null 2>&1 </dev/null &
sleep 3.5
hyprctl clients -j | python3 -c "
import json,sys
n=sum(1 for c in json.load(sys.stdin) if c['class']=='Y11B')
raise SystemExit(0 if n==1 else 1)" || { echo "ABORT: the liveness probe did not appear"; exit 1; }

dsp "hl.dsp.window.move({workspace = $WS_AWAY, window = [[address:$ADDR]], follow = false})"
sleep 1.2

# Z1's state: the away desktop has been SHOWN and left, so its render offset is
# parked. This is the state the user actually has.
for i in 1 2; do
    dsp "hl.dsp.focus({workspace = $WS_AWAY})"; sleep 1.3
    dsp "hl.dsp.focus({workspace = $WS_HOME})"; sleep 1.3
done
ACTIVE=$(hyprctl activeworkspace -j | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
[ "$ACTIVE" = "$WS_HOME" ] || { echo "ABORT: standing on ws $ACTIVE"; exit 1; }
WSNOW=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((str(c['workspace']['id']) for c in json.load(sys.stdin) if c['class']=='Y11A'), '?'))")
[ "$WSNOW" = "$WS_AWAY" ] || { echo "ABORT: Y11A is on ws $WSNOW"; exit 1; }
echo "Y11A on ws $WSNOW (not active), standing on ws $ACTIVE, desktops swapped twice"

read -r IX IY <<< "$(hyprctl clients -j | python3 /mnt/host/x47_cell.py Y11A)"
read -r PX PY PW PH <<< "$(hyprctl clients -j | python3 /mnt/host/x47_cell.py panel)"
echo "icon=$IX,$IY  panel=$PX,$PY ${PW}x${PH}"

BAND="0,$((PY - 24)) ${W}x$((PH + 24))"
shot() { grim -g "$BAND" "$OUT/$TAG-$1.png" 2>/dev/null; }
PARKX=$((W - 60)); PARKY=60

ov on; sleep 2.5

# controls: nothing hovered, two frames the same distance apart as the hovers
warp $PARKX $PARKY; sleep 1.4
shot c0
sleep 0.5
shot c1

warp_or_die $IX $IY
sleep 0.8            # past PANEL_IN_MS, panel settled
shot h0
grim "$OUT/$TAG-p0.png" 2>/dev/null      # whole screen: the liveness probe
sleep 0.5            # the clock ticks every 80ms, so this must differ
shot h1
grim "$OUT/$TAG-p1.png" 2>/dev/null
sleep 0.5
shot h2

warp $PARKX $PARKY; sleep 1.6
echo "frames: $(ls $OUT/$TAG-*.png | wc -l)"
echo Y11_RIG_OK
