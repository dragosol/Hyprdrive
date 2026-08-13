#!/usr/bin/env bash
# Gate x48_results_band -- OVERVIEW_CPP_SPEC 13.12 X60, which SUPERSEDES X48's
# placement (and DoD 23's "the results own the bottom half"): the selected
# result row sits ABOVE the tile block, between the search bar and the desktop
# strip; the band's space comes FROM the tile grid; and nothing is shoved off --
# the tile block's foot stays clear of the dock, which is X48's own surviving
# constraint. NODRIFT + LIVE brackets. Renamed from x48_results_band, which
# graded the pre-X60 layout and had been reporting X60's own behaviour as a
# defect; see the header of scripts/x48_gate.py.
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
        echo "GATE x48_results_band: self-verdict $tok missing" >&2
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
    || { rm -rf "$GDIR"; echo "GATE x48_results_band: could not stage the grader" >&2; exit 1; }
python3 "$GDIR/x48_gate.py" "$TAG"; rc=$?
rm -rf "$GDIR"
[ "$rc" = 0 ] || exit 1

echo "GATE x48_results_band: PASS"
