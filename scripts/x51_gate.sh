#!/usr/bin/env bash
# X51 gate: text served from the surviving cache must be PIXEL-IDENTICAL to text
# rendered fresh. Frame A is the first open after a compositor restart (every
# string cold); frame B is a later open (every string cached). A==B is the pass.
#
# Identical frames are also what a stalled Virtual-1 produces, so C is a control
# that MUST differ: a typed query the other two never had.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
# dsp()/ov() come from lib/rig.sh. rig_env also exports WAYLAND_DISPLAY, which
# the old block never set -- grim used to depend on inheriting it by luck.
systemctl --user stop hyprwall.timer 2>/dev/null

# NOTHING LIVE IN THE FRAME. The claim is pixel-identity, and A and B are about
# twenty seconds apart: any window that redraws on its own breaks it for a
# reason that has nothing to do with the glyph cache. This gate restarts the
# compositor, so it comes back to a session gate_slate has never seen -- and
# gdm's own gcr-prompter ("Unlock Login Keyring") lands dead centre with a
# BLINKING TEXT CURSOR in its password field. Measured 2026-08-12: with the bar
# masked, A and B still differed by 44 px, all of them that cursor and one
# strip mini showing it.
#
# So: every toplevel dies (the same rule and the same reason as gate_slate),
# and one deliberately STATIC fixture goes back, because a tile with a label is
# most of the text this gate is about. cursor_blink_interval=0 is the whole
# point of it -- kitty blinks its cursor by default.
hyprctl clients -j 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('pid',0) > 0: print(c['pid'])" | xargs -r kill -9 2>/dev/null
sleep 1.5
setsid kitty -c NONE --class X51FIX -T X51FIX -o background='#182030' -o background_opacity=1.0 \
    -o cursor_blink_interval=0 -o confirm_os_window_close=0 --hold sh -c 'clear' >/dev/null 2>&1 </dev/null &
sleep 2.5
hyprctl clients -j | grep -q X51FIX || { echo "ABORT: the X51 fixture did not appear" >&2; exit 1; }
dsp 'hl.dsp.focus({workspace = 1})'; sleep 0.8

ov on; sleep 4; grim /mnt/host/x51_A_coldtext.png
# The comparison masks the chrome that is not the plugin -- the quickshell bar's
# clock and CPU readouts tick between A and B whatever the glyph cache does.
# Dumped WITH THE OVERVIEW UP, the state all three frames are taken in.
hyprctl layers -j > /mnt/host/x51_layers.json
ov off; sleep 2
for i in 1 2 3 4; do ov on; sleep 3; ov off; sleep 1.5; done
ov on; sleep 4; grim /mnt/host/x51_B_cachedtext.png
ydotool key 37:1 37:0; sleep 2; grim /mnt/host/x51_C_control.png
ov off
echo done
