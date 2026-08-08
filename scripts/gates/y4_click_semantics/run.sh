#!/usr/bin/env bash
# Y4 gate: plain dock click stashes ALL of an app's windows, a second click
# restores all, CTRL+click cycles and never stashes (13.14 Y4).
#
# The rigs print STATE lines with their expectations in the headers; this
# wrapper hardens those printed verdicts to exit codes (the promotion note in
# the audit asked for exactly that):
#   AFTER-CLICK1  3/3 stashed     all three minimized
#   AFTER-CLICK2  0/3 stashed     all three back
#   AFTER-CTRL    0/3 stashed     ctrl never stashes
#   cycle         focus moves to a different window on >= 2 of 4 ctrl+clicks
#     (the DoD's "visiting a different window at least twice over 3-4
#     ctrl+clicks" -- a dead cycle keeps focus parked)
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

# The rigs aim with the /mnt/host copy of the cell predictor; the repo copy is
# canonical, so place it there when missing or stale.
ensure_share() {
    cmp -s "scripts/$1" "/mnt/host/$1" 2>/dev/null && return 0
    cp -f "scripts/$1" "/mnt/host/$1" \
        || { echo "NEEDS-HOST: cannot place scripts/$1 at /mnt/host -- share not mounted?" >&2; return 1; }
}
ensure_share x47_cell.py || exit 3

cleanup() { # the rigs leave their three Y4A fixtures mapped
    hyprctl clients -j 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('class')=='Y4A' and c.get('pid',0)>0: print(c['pid'])" \
        | xargs -r kill -9 2>/dev/null
    return 0
}
trap cleanup EXIT

echo "=== y4_probe (minimize-all / restore-all / ctrl never stashes) ==="
PROBE_OUT=$(bash scripts/y4_probe.sh 2>&1); rc=$?
printf '%s\n' "$PROBE_OUT"
[ $rc -eq 0 ] || { echo "Y4 FAIL -- probe exited $rc"; exit 1; }
grep -q 'Y4_PROBE_OK' <<< "$PROBE_OUT" || { echo "Y4 FAIL -- probe never finished"; exit 1; }

fail=0
grep -E '^AFTER-CLICK1' <<< "$PROBE_OUT" | grep -q '3/3 stashed' \
    || { echo "Y4 FAIL -- plain click 1 did not stash all three"; fail=1; }
grep -E '^AFTER-CLICK2' <<< "$PROBE_OUT" | grep -q '0/3 stashed' \
    || { echo "Y4 FAIL -- plain click 2 did not restore all three"; fail=1; }
grep -E '^AFTER-CTRL' <<< "$PROBE_OUT" | grep -q '0/3 stashed' \
    || { echo "Y4 FAIL -- ctrl+click stashed something"; fail=1; }
[ $fail -eq 0 ] || exit 1

echo "=== y4_cycle (ctrl+click steps through the app's windows) ==="
CYCLE_OUT=$(bash scripts/y4_cycle.sh 2>&1); rc=$?
printf '%s\n' "$CYCLE_OUT"
[ $rc -eq 0 ] || { echo "Y4 FAIL -- cycle rig exited $rc"; exit 1; }

# 4 clicks, re-aimed every time; live iff focus CHANGED on at least two of them.
awk -F'focus=' '
    /^start focus=/   { prev=$2 }
    /^ctrl\+click /   { n++; if ($2 != prev && $2 != "" && $2 != "(none)") t++; prev=$2 }
    END {
        printf "clicks=%d focus-changes=%d\n", n, t
        exit !(n >= 3 && t >= 2)
    }' <<< "$CYCLE_OUT" \
    || { echo "Y4 FAIL -- ctrl+click cycle never visited a different window twice"; exit 1; }

echo "Y4 PASS -- click semantics hold and the ctrl cycle is live"
exit 0
