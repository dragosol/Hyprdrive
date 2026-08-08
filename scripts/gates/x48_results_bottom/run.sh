#!/usr/bin/env bash
# Gate x48_results_bottom -- OVERVIEW_CPP_SPEC 13.12 X48 / DoD 23: the selected
# result row's top is below the overview's half-way line; DoD 18: search row +
# desktop strip are fixed chrome (quiet between a0 and b); tiles yield space
# DOWNWARD (top not descending, foot rising); NODRIFT + LIVE brackets.
# GUEST-side orchestrator: x48 fixture -> x48 run -> x48_gate.py. Exits 0 iff
# green. (This rig is also the shared fixture provider for g5/x50/settled_shot:
# it writes /mnt/host/x48/mon.)
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

TAG=${1:-suite}
hyprwall_pause
RIG_HEADLESS=1  # the fixture hand-rolls its headless output and clears its own
                # trap so the fixture survives the fixture SCRIPT; arm
                # headless_off here so ANY exit of the GATE puts Virtual-1 back
                # [x47_rig.sh:37-42]
trap 'headless_off; hyprwall_resume' EXIT

step() { # step TOKEN CMD... -- run, echo through, require the self-verdict
    local tok=$1; shift
    local log; log=$(mktemp)
    "$@" 2>&1 | tee "$log"
    if ! grep -q "$tok" "$log"; then
        rm -f "$log"
        echo "GATE x48_results_bottom: self-verdict $tok missing" >&2
        return 1
    fi
    rm -f "$log"
}

step X48_FIXTURE_OK bash scripts/x48_rig.sh fixture    || exit 1
alive_or_die "after x48 fixture"
step X48_RUN_OK     bash scripts/x48_rig.sh run "$TAG" || exit 1
alive_or_die "after x48 run"

# x48_gate.py resolves its frames dir relative to ITS OWN location (parent/x48,
# the host-side share checkout). Guest-side the frames are /mnt/host/x48, so
# grade from a scratch copy of the untouched grader next to a symlink.
GDIR=$(mktemp -d)
cp scripts/x48_gate.py "$GDIR/" && ln -s /mnt/host/x48 "$GDIR/x48" \
    || { rm -rf "$GDIR"; echo "GATE x48_results_bottom: could not stage the grader" >&2; exit 1; }
python3 "$GDIR/x48_gate.py" "$TAG"; rc=$?
rm -rf "$GDIR"
[ "$rc" = 0 ] || exit 1

echo "GATE x48_results_bottom: PASS"
