#!/usr/bin/env bash
# Gate x50_pill_docks -- OVERVIEW_CPP_SPEC 13.12 X50: the search bar animates
# up when results appear. DOCK (pill appears in the band under the work-area
# top edge, vanishes from rest), NOMATCH negative control (pill widens but the
# top band stays empty -- catches dock-on-first-keystroke), CLEAR (Esc returns
# it); band self-calibrated from layers.json + the NOMATCH frame.
# GUEST-side orchestrator: shared x48 fixture -> x50 rig -> x50 flight burst ->
# x50_gate.py. Exits 0 iff green.
# NOTE: x50_gate.py machine-grades the dock/nomatch/clear half; the flight
# burst frames (animate-move half) are captured for the record -- no automated
# grader exists for them yet.
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
trap 'pkill -x kitty 2>/dev/null; headless_off; hyprwall_resume' EXIT

step() { # step TOKEN CMD... -- run, echo through, require the self-verdict
    local tok=$1; shift
    local log; log=$(mktemp)
    "$@" 2>&1 | tee "$log"
    if ! grep -q "$tok" "$log"; then
        rm -f "$log"
        echo "GATE x50_pill_docks: self-verdict $tok missing" >&2
        return 1
    fi
    rm -f "$log"
}

step X48_FIXTURE_OK bash scripts/x48_rig.sh fixture      || exit 1
alive_or_die "after x48 fixture"
step X50_RUN_OK     bash scripts/x50_rig.sh "$TAG"       || exit 1
alive_or_die "after the dock/nomatch/clear rig"
step X50_FLIGHT_OK  bash scripts/x50_flight.sh "$TAG"    || exit 1
alive_or_die "after the flight capture"

# x50_gate.py takes the frames dir as its first argument -- guest-side that is
# /mnt/host/x50, no path bridge needed.
python3 scripts/x50_gate.py /mnt/host/x50 "$TAG" || exit 1

echo "GATE x50_pill_docks: PASS"
