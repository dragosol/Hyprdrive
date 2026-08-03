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
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)

TAG=${1:?usage: x47_rig.sh <tag>}
OUT=/mnt/host/x47; mkdir -p $OUT

dsp()  { hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }
ov()   { dsp "hl.plugin.scrolloverview.overview([[$1]])"; }
# ydotool's absolute space is HALF this guest's output (standing rig rule).
warp() { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; }

cfg() { hyprctl eval "hl.config({plugin={scrolloverview={dock={$1}}}}) return 0" >/dev/null 2>&1; }

# RESTORE ON EVERY EXIT PATH, including the aborts below. An earlier run of this
# rig exited through one of those aborts and left the guest on a headless output
# with Virtual-1 disabled -- so the VM's actual screen was blank, and the next
# thing to re-enable Virtual-1 put two outputs at 0x0 and Hyprland's "monitor
# layout is set up incorrectly, HEADLESS-1 overlaps" banner came up. A rig that
# swaps the display out is only safe if the swap back cannot be skipped.
restore() {
    ov off
    cfg "autohide=true, show_favorites=true, show_apps_button=true, show_trash=true, show_mounts=false"
    hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = false})" >/dev/null 2>&1
    sleep 1.2
    # Virtual-1 comes back FIRST: removing the last output while it is the only
    # enabled one is what leaves the session with nowhere to put its windows.
    for m in $(hyprctl monitors all -j | python3 -c "
import json,sys
print(' '.join(m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')))"); do
        hyprctl output remove "$m" >/dev/null 2>&1; sleep 0.4
    done
    systemctl --user start hyprwall.timer 2>/dev/null
}
trap restore EXIT

systemctl --user stop hyprwall.timer 2>/dev/null
# Put it back even if this run dies in a way the trap cannot catch (SIGKILL, or
# the compositor going down under it), so the desktop is not left frozen.
systemd-run --user --on-active=30min systemctl --user start hyprwall.timer >/dev/null 2>&1

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5

# HEADLESS OUTPUT, Virtual-1 DISABLED. Virtual-1 draws ~1fps while no viewer is
# attached to the VM, so grim hands back the same stale frame over and over --
# the first run of this rig scored 0 changed pixels between two frames of a
# counter ticking every 80ms, which is that failure and nothing else. Same
# swap x28_fixture.sh makes, for the same reason.
hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = false})" >/dev/null 2>&1; sleep 1.2
for m in $(hyprctl monitors all -j | python3 -c "
import json,sys
print(' '.join(m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')))"); do
    hyprctl output remove "$m" >/dev/null 2>&1; sleep 0.4
done
sleep 1
hyprctl output create headless >/dev/null 2>&1; sleep 1.5
HL=$(hyprctl monitors all -j | python3 -c "
import json,sys
hs=[m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')]
print(hs[0] if len(hs)==1 else '')")
[ -n "$HL" ] || { echo "ABORT: expected exactly one headless output"; exit 1; }
# Same MODE as Virtual-1, deliberately: the dock geometry this rig predicts is a
# function of the monitor width, and ydotool's absolute space is half of THIS
# guest's 2560x1600 whatever output is enabled. Letting the headless come up at
# its own default would silently move both.
# `hyprctl keyword monitor` answers "can't work with non-legacy parsers" on 0.56;
# the mode has to go through hl.monitor, same as the enable/disable calls above.
hyprctl eval "return hl.monitor({output = [[$HL]], mode = [[2560x1600@60]], position = [[0x0]], scale = 1})" >/dev/null 2>&1; sleep 1.2
hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = true})" >/dev/null 2>&1; sleep 1.5

read -r MON W H <<< "$(hyprctl monitors -j | python3 -c "
import json,sys
m=json.load(sys.stdin)[0]; print(m['name'], m['width'], m['height'])")"
echo "monitor: $MON ${W}x${H}"
case "$MON" in HEADLESS*) ;; *) echo "ABORT: expected the headless output, got $MON"; exit 1 ;; esac
[ "$W" = 2560 ] && [ "$H" = 1600 ] || { echo "ABORT: headless came up ${W}x${H}, not 2560x1600"; exit 1; }

# `hyprctl keyword` is DEAD in 0.56 -- every call answers "can't work with
# non-legacy parsers" on stderr and returns 0, so a rig that used it configured
# nothing and said nothing. Config goes through cfg() (hl.config), and want()
# reads the value back to prove it landed.
want() {
    read -r VAL SET <<< "$(hyprctl getoption "plugin:scrolloverview:dock:$1" | head -2 | awk '{print $2}' | tr '\n' ' ')"
    [ "$VAL" = "$2" ] || { echo "ABORT: dock:$1 is $VAL, wanted $2"; exit 1; }
}

# THE DOCK HOLDS RUNNING CLASSES AND NOTHING ELSE for this run. x47_cell.py
# predicts icon centres from the class list, and a rig that had to model the
# favourites file, the .desktop lookups behind it and the Locations items would
# be a second implementation of dockItems() -- which is the thing most likely to
# drift out of step with the one under test. Switching the other sources OFF is
# what keeps the prediction a prediction rather than a read-back.
cfg "autohide=false, show_favorites=false, show_apps_button=false, show_trash=false, show_mounts=false"
sleep 0.8
for k in autohide show_favorites show_apps_button show_trash show_mounts; do want $k false; done

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
for i in 1 2; do
    setsid kitty -c NONE --class X47A -o background='#101820' -o background_opacity=1.0 \
        -o confirm_os_window_close=0 --hold sh -c clear >/dev/null 2>&1 </dev/null &
    sleep 2.2
done
# A second class, so FOLLOWS has somewhere to travel to.
setsid kitty -c NONE --class X47B -o background='#302010' -o background_opacity=1.0 \
    -o confirm_os_window_close=0 --hold sh -c clear >/dev/null 2>&1 </dev/null &
sleep 2.4

N=$(hyprctl clients -j | python3 -c "
import json,sys
print(sum(1 for c in json.load(sys.stdin) if c['class']=='X47A'))")
[ "$N" = "3" ] || { echo "ABORT: expected 3 X47A windows, got $N"; exit 1; }
hyprctl clients -j > $OUT/$TAG-clients.json

read -r AX AY <<< "$(hyprctl clients -j | python3 /mnt/host/x47_cell.py X47A)"
read -r BX BY <<< "$(hyprctl clients -j | python3 /mnt/host/x47_cell.py X47B)"
read -r PX PY PW PH <<< "$(hyprctl clients -j | python3 /mnt/host/x47_cell.py panel)"
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
# frames are what a HEALTHY run looks like there.
grim "$OUT/$TAG-p0.png" 2>/dev/null
sleep 0.5
grim "$OUT/$TAG-p1.png" 2>/dev/null

# --- RISES + LIVE ----------------------------------------------------------
warp $AX $AY
sleep 0.4
# The pointer is where the rig THINKS it is, or nothing below means anything.
# Every silent failure this project has recorded around input started with a
# warp that did not land where the rig aimed it.
read -r CX CY <<< "$(hyprctl cursorpos | tr -d ',')"
echo "cursor after warp: $CX,$CY (aimed $AX,$AY)"
[ "$(( CX > AX - 6 && CX < AX + 6 && CY > AY - 6 && CY < AY + 6 ))" = 1 ] \
    || { echo "ABORT: warp landed at $CX,$CY, not $AX,$AY"; exit 1; }
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

# The overview, the dock config and the DISPLAY all go back in restore(), on the
# EXIT trap, so an abort restores as thoroughly as a clean finish does.
echo "frames: $(ls $OUT/$TAG-*.png | wc -l)"
echo X47_RIG_OK
