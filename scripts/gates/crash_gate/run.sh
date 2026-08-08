#!/usr/bin/env bash
# crash_gate -- dangling-listener compositor segfault ("segfault at X ip X
# error 14" in the plugin mmap range): search open -> tight backspace loop ->
# mouse move must SURVIVE. One clean lap means nothing at the ~2/3 hit rate;
# 8 clean laps ~= 99.98%. crash_gate.sh always exits 0 -- the verdict is its
# RESULT line. Green = 0/N deaths AND 0 new kernel segfault lines in journal.
# Depends on scripts/x26_open.sh (the shared opener -- a bespoke opener caused
# a false negative once) and /mnt/host/x26 (crash_repro mkdirs it).
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

# x26_open.sh stops hyprwall.timer and never restarts it; resume on the way
# out whatever happens.
trap hyprwall_resume EXIT

N=8
LOG=/mnt/host/x26/crash-gate-run.log
mkdir -p /mnt/host/x26
bash scripts/crash_gate.sh "$N" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || exit "$rc"
grep -q "^RESULT: 0/$N deaths, 0 new kernel segfaults" "$LOG"
