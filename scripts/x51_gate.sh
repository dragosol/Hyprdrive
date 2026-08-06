#!/usr/bin/env bash
# X51 gate: text served from the surviving cache must be PIXEL-IDENTICAL to text
# rendered fresh. Frame A is the first open after a compositor restart (every
# string cold); frame B is a later open (every string cached). A==B is the pass.
#
# Identical frames are also what a stalled Virtual-1 produces, so C is a control
# that MUST differ: a typed query the other two never had.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
dsp() { hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }
ov()  { dsp "hl.plugin.scrolloverview.overview([[$1]])"; }
systemctl --user stop hyprwall.timer 2>/dev/null

ov on; sleep 4; grim /mnt/host/x51_A_coldtext.png; ov off; sleep 2
for i in 1 2 3 4; do ov on; sleep 3; ov off; sleep 1.5; done
ov on; sleep 4; grim /mnt/host/x51_B_cachedtext.png
ydotool key 37:1 37:0; sleep 2; grim /mnt/host/x51_C_control.png
ov off
echo done
