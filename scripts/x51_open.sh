#!/usr/bin/env bash
# X51: what does the OVERVIEW OPEN pay? Cold (first open after a fresh
# compositor) vs warm (second open, every cache resident). Runs IN THE GUEST.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
LOG=/tmp/scrolloverview-prof.log
dsp() { hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }
ov()  { dsp "hl.plugin.scrolloverview.overview([[$1]])"; }

systemctl --user stop hyprwall.timer 2>/dev/null
: > $LOG
ov on;  sleep 3
echo "=== COLD OPEN"; cat $LOG
ov off; sleep 2
: > $LOG
ov on;  sleep 3
echo "=== WARM OPEN"; cat $LOG
ov off
