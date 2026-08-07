#!/bin/bash
# Runs crash_repro.sh N times and counts BOTH deaths and kernel segfaults.
# A single SURVIVED means nothing at a ~2/3 hit rate: 8 clean runs is ~99.98%.
set -u
N=${1:-8}
export XDG_RUNTIME_DIR=/run/user/$(id -u)
SEG0=$(journalctl -b --no-pager 2>/dev/null | grep -c "Hyprland.*segfault")
DEATHS=0
for i in $(seq $N); do
    R=$(bash ~/overview-cpp/scripts/crash_repro.sh 2>&1 | tail -1)
    echo "run $i: $R"
    [ "$R" != SURVIVED ] && DEATHS=$((DEATHS+1))
done
SEG1=$(journalctl -b --no-pager 2>/dev/null | grep -c "Hyprland.*segfault")
echo "RESULT: $DEATHS/$N deaths, $((SEG1-SEG0)) new kernel segfaults"
