#!/usr/bin/env bash
# X51: cold text renders per overview OPEN, across N successive opens.
# The strings a rice draws are the same every time, so a cache that survives a
# close should converge to zero. Runs IN THE GUEST.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
LOG=$XDG_RUNTIME_DIR/hyprdrive-prof.log   # DebugPaths.hpp
dsp() { hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }
ov()  { dsp "hl.plugin.hyprdrive.overview([[$1]])"; }
systemctl --user stop hyprwall.timer 2>/dev/null
N=${1:-5}
for i in $(seq 1 $N); do
    : > $LOG
    ov on;  sleep 3
    # frame 3 carries the cumulative counters for this open
    echo "open $i: $(grep 'f=3' $LOG | tail -1 | grep -o 'TEXT\[[^]]*\]  ICON\[cold=[0-9]*') | renderSearch $(grep 'f=3' $LOG | tail -1 | grep -o 'renderSearch=[ 0-9.]*ms')"
    ov off; sleep 2
done
