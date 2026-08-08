#!/usr/bin/env bash
# Gate g1 -- OVERVIEW_CPP_SPEC 13.11: type-to-search from anywhere.
#   * SPACE on an empty query is a no-op (GNOME whitespace rule), bracketed by
#     must-move controls that fail on a frozen output   [g1_rig.sh + g1_gate.py]
#   * negative half: TAB/BACKSPACE/F5 must not start a search
#   * last clause: compose sequence composes ('e -> e-acute, proven by differing
#     from raw passthrough) and Compose alone activates the bar (ESC cascade)
#     [g1c_rig.sh + g1c_grade.py]
# GUEST-side orchestrator: fixture -> run -> grade -> g1c arm on the same
# fixture. Exits 0 iff every claim is green.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

TAG=${1:-suite}
CTAG=${TAG}c    # g1c shares OUT=/mnt/host/g1 and reuses the 00/01 control
                # names; a distinct tag keeps it from clobbering g1's frames
hyprwall_pause
RIG_HEADLESS=1  # g1's fixture hand-rolls its headless output with no trap of
                # its own; arm headless_off so ANY exit puts Virtual-1 back
                # [x47_rig.sh:37-42]
trap 'headless_off; hyprwall_resume' EXIT

step() { # step TOKEN CMD... -- run, echo through, require the self-verdict
    local tok=$1; shift
    local log; log=$(mktemp)
    "$@" 2>&1 | tee "$log"
    if ! grep -q "$tok" "$log"; then
        rm -f "$log"
        echo "GATE g1: self-verdict $tok missing" >&2
        return 1
    fi
    rm -f "$log"
}

step G1_FIXTURE_OK bash scripts/g1_rig.sh fixture    || exit 1
alive_or_die "after g1 fixture"
step G1_RUN_OK     bash scripts/g1_rig.sh run "$TAG" || exit 1
alive_or_die "after g1 run"

# g1_gate.py hardcodes the HOST path /home/dragos/hyprvm/share/g1; in the guest
# that same directory is /mnt/host/g1. Bridge with a symlink, never by editing
# the grader.
SHARE=/home/dragos/hyprvm/share
if [ ! -e "$SHARE/g1/$TAG-00-ctrlA.png" ]; then
    mkdir -p /home/dragos/hyprvm 2>/dev/null
    [ -e "$SHARE" ] || ln -s /mnt/host "$SHARE" 2>/dev/null
fi
if [ ! -e "$SHARE/g1/$TAG-00-ctrlA.png" ]; then
    echo "NEEDS-HOST: g1_gate.py reads $SHARE/g1 and this guest cannot map it onto /mnt/host/g1" >&2
    exit 3
fi
python3 scripts/g1_gate.py "$TAG" || exit 1

# --- last clause: compose (g1c, reuses the fixture + mon file) ---------------
step G1C_RUN_OK bash scripts/g1c_rig.sh "$CTAG" || exit 1
alive_or_die "after g1c run"
python3 scripts/gates/g1/g1c_grade.py /mnt/host/g1 "$CTAG" || exit 1

echo "GATE g1: PASS"
