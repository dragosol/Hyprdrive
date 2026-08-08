#!/usr/bin/env bash
# Gate g5 -- OVERVIEW_CPP_SPEC 13.4: two result layouts with PER-PROVIDER caps.
# NODRIFT, LIVE (graded on the same frames -- the X47 lesson), FOUND, CAPS >= 6
# distinct selection boxes, GRID (at least one icon CELL and one wide ROW);
# TAB-walk, never DOWN (DOWN walks the tile grid, scrollOverview.cpp:2413).
# GUEST-side orchestrator: shared x48 fixture -> g5 TAB-walk rig -> g5_gate.py.
# Exits 0 iff green.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

TAG=${1:-suite}
hyprwall_pause
RIG_HEADLESS=1  # the x48 fixture hand-rolls its headless output and clears its
                # own trap so the fixture survives; arm headless_off here so
                # ANY exit of the GATE puts Virtual-1 back [x47_rig.sh:37-42]
trap 'headless_off; hyprwall_resume' EXIT

step() { # step TOKEN CMD... -- run, echo through, require the self-verdict
    local tok=$1; shift
    local log; log=$(mktemp)
    "$@" 2>&1 | tee "$log"
    if ! grep -q "$tok" "$log"; then
        rm -f "$log"
        echo "GATE g5: self-verdict $tok missing" >&2
        return 1
    fi
    rm -f "$log"
}

# g5 does not build its own output: it reads /mnt/host/x48/mon, written by the
# shared x48 fixture. Always rebuild that fixture -- a stale mon file names an
# output that no longer exists.
step X48_FIXTURE_OK bash scripts/x48_rig.sh fixture || exit 1
alive_or_die "after x48 fixture"
step G5_RUN_OK      bash scripts/g5_rig.sh "$TAG"   || exit 1
alive_or_die "after g5 run"

# g5_gate.py resolves its frames dir relative to ITS OWN location (parent/g5,
# the host-side share checkout). Guest-side the frames are /mnt/host/g5, so
# grade from a scratch copy of the untouched grader next to a symlink.
GDIR=$(mktemp -d)
cp scripts/g5_gate.py "$GDIR/" && ln -s /mnt/host/g5 "$GDIR/g5" \
    || { rm -rf "$GDIR"; echo "GATE g5: could not stage the grader" >&2; exit 1; }
python3 "$GDIR/g5_gate.py" "$TAG"; rc=$?
rm -rf "$GDIR"
[ "$rc" = 0 ] || exit 1

echo "GATE g5: PASS"
