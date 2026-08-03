#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC 13.9 X30 acceptance rig. Runs IN THE GUEST; the pixels are
# analysed on the HOST by scripts/x30_gate.py, because the guest has no numpy.
#
# The pill is 0.19-alpha frost, so it is not findable by colour -- every frame
# here is measured by the same A/B the X27 gate uses, against control frames
# taken with the dock away. That is also what stops the rig passing vacuously:
# if the dock never drew at all, every frame is the control and the gate has
# nothing to measure.
#
# The reveal is driven with RELATIVE ydotool motion, never absolute: the barrier
# reads the pointer's delta, and an absolute warp does not have one. A rig that
# warped to the bottom edge would report "pressure never builds" for a reason
# that has nothing to do with the plugin.
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/x30
mkdir -p $OUT

read -r MON W H <<< "$(hyprctl monitors -j | python3 -c "
import json,sys
m = json.load(sys.stdin)[0]
print(m['name'], m['width'], m['height'])")"

# `hyprctl keyword` is gone in 0.56 and exits 0 having changed nothing -- see
# x27_capture.sh, where that cost a whole run.
key()  { hyprctl eval "return hl.config({ plugin = { scrolloverview = { dock = { $1 = $2 } } } })" >/dev/null; }
ov()   { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null; }
shot() { grim -o "$MON" $OUT/$1.png; }

# ydotool's ABSOLUTE motion is 1:1 with the output here. The half-space note in
# x24_dock_click.sh does NOT hold at 2560x1600; halving parked the cursor in the
# middle of the screen and every push in this rig missed the barrier entirely.
warp() { ydotool mousemove -a -x $1 -y $2 2>/dev/null; }
park() { warp $((W / 2)) $((H / 2)); sleep 0.4; }

push() { for _ in $(seq 1 $1); do ydotool mousemove -x 0 -y $2 2>/dev/null; sleep 0.02; done; }

# Sit ON the barrier having pressed it almost not at all. Getting there is the
# whole difficulty of this rig: ydotool's ABSOLUTE motion is a relative move
# under the skin, so warping straight to the last row hands the barrier a
# ~1600px delta and reveals the dock instantly -- the first run of this rig did
# exactly that and its sub-threshold push "passed" while measuring nothing.
#
# So: warp to 12px ABOVE the barrier, which lands outside the band and resets
# the pressure whatever the warp's delta was, then walk in on 4px steps. Only
# the steps that land in the band count, so this arrives with <= ~12px of
# pressure on the clock.
edge() {
    warp $((W / 2)) $((H - 12)); sleep 0.5
    push 4 4
    sleep 0.3
}

case "${1:?usage: x30_rig.sh <phase>}" in

fixture)
    # A wallpaper rotation moves every pixel and this rig is entirely pixel-based.
    systemctl --user stop hyprwall.timer 2>/dev/null
    systemd-run --user --on-active=40min systemctl --user start hyprwall.timer >/dev/null 2>&1

    ov off 2>/dev/null; sleep 0.5
    pkill -f 'kitty --class X30' 2>/dev/null; sleep 0.6
    # kitty, never foot: an opaque terminal defeats the compositor blur the pill
    # is measured through (RICE_PROGRESS, frost rule).
    setsid -f kitty --class X30A --override background=#202020 -o confirm_os_window_close=0 \
        sh -c 'while :; do sleep 1; done' </dev/null >/dev/null 2>&1
    sleep 2.0

    # Flat, unaccelerated pointer motion for the run: the barrier counts PIXELS
    # of delta, and libinput's acceleration curve would make a 4px step worth
    # something other than 4px -- which is the one thing the threshold phases
    # cannot tolerate.
    hyprctl eval "return hl.config({ input = { accel_profile = [[flat]], sensitivity = 0.0 } })" >/dev/null

    key autohide      true
    key autohide_ms   200
    key show_delay_ms 250
    key hide_delay_ms 200
    key enabled       true
    park; sleep 1.5
    echo "X30_FIXTURE mon=$MON ${W}x${H}"
    ;;

# Controls, taken with the dock hidden and the pointer parked far from the
# barrier. Three of them, bracketing nothing yet -- the gate needs two gaps to
# build its noise mask, because a slow animation can sit still across one.
base)
    park; sleep 1.2; shot off1
          sleep 1.2; shot off2
          sleep 1.2; shot off3
    echo BASE_OK
    ;;

# P1. `dock-fixed`: with autohide OFF the pill is simply out, which is both the
# "hidden by default" control and the full-height reference every other phase
# is measured against.
fixed)
    key autohide false; sleep 1.5; shot fixed
    key autohide true;  sleep 1.5
    echo FIXED_OK
    ;;

# P2. `require-pressure-to-show` at `pressure-threshold`. Three phases, because
# two would not be enough to tell "the threshold is enforced" from "some fixed
# amount of shoving reveals it": the SAME push is run against the stock 100 and
# against a lowered threshold, and only the number changes between them.
weak)
    park; sleep 0.8
    edge
    push 8 8
    sleep 1.2; shot weak
    echo WEAK_OK
    ;;

# The same push again, with the threshold dropped under it. If this frame looks
# like `weak`, the plugin is not reading `pressure-threshold` at all.
lowthresh)
    park; sleep 1.5
    key pressure_threshold 20.0
    edge
    push 8 8
    sleep 1.2; shot lowthresh
    key pressure_threshold 100.0
    park; sleep 1.5
    echo LOWTHRESH_OK
    ;;

strong)
    park; sleep 1.5
    edge
    push 40 20
    sleep 1.4; shot strong
    echo STRONG_OK
    ;;

# P3. `hide-delay`: take the pointer off the pill and it goes away again.
leave)
    park; sleep 1.6; shot leave
    echo LEAVE_OK
    ;;

# P4. Pinned in the overview (section 10 clause 6) DESPITE autohide, and with no
# pressure anywhere near the barrier. The A/B is against dock:enabled false,
# because the overview repaints the whole screen and the desktop controls are
# useless there.
overview)
    park; sleep 1.5
    ov on; sleep 2.0; shot ov_on
    key enabled false; sleep 1.5; shot ov_off
    key enabled true;  sleep 1.0
    ov off; sleep 1.5
    echo OVERVIEW_OK
    ;;

# P5. `autohide-in-fullscreen` true: the barrier keeps working under a
# fullscreen window instead of the dock locking itself away. The control is the
# same fullscreen desktop with no pressure applied, so a pass cannot come from
# the fullscreen repaint.
fullscreen)
    park; sleep 1.0
    hyprctl eval "return hl.dispatch(hl.dsp.window.fullscreen({ mode = 'fullscreen', action = 'on' }))" >/dev/null
    sleep 2.0; shot fs_ctl1
    sleep 1.2; shot fs_ctl2
    edge; push 40 20
    sleep 1.4; shot fs_on
    hyprctl eval "return hl.dispatch(hl.dsp.window.fullscreen({ mode = 'fullscreen', action = 'off' }))" >/dev/null
    park; sleep 1.5
    echo FULLSCREEN_OK
    ;;

# P6. It SLIDES, it does not teleport. At the reference's 200ms the reveal is
# over before grim has opened the file (the X22 lesson), so the animation is
# slowed to 2s for this phase only and restored at the end of it.
slide)
    key autohide_ms 2000
    park; sleep 1.5
    edge
    push 40 20
    for i in $(seq 1 12); do shot slide$i; done
    sleep 1.5
    key autohide_ms 200
    park; sleep 1.5
    echo SLIDE_OK
    ;;

*)
    echo "ABORT: unknown phase $1"; exit 1 ;;
esac
