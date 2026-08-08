#!/usr/bin/env bash
# GATE hover_overshoot -- tile hover must not overshoot (zero-bounce spring,
# the standing Apple-motion rule). Guest-side: hover_rig.sh captures the band
# frames to /mnt/host/hover, hover_gate.py grades them here (PIL+numpy are in
# the guest). The grader hardcodes the HOST share path, so we bridge it with a
# symlink instead of editing the grader.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

TAG=${1:-suite}
hyprwall_pause                       # hover_rig stops the timer and never restarts it
trap 'pkill -x kitty 2>/dev/null; hyprwall_resume' EXIT

step() { # step TOKEN CMD... -- run, echo through, require the self-verdict
    local tok=$1; shift
    local log; log=$(mktemp)
    "$@" 2>&1 | tee "$log"
    if ! grep -q "$tok" "$log"; then
        rm -f "$log"
        echo "GATE hover_overshoot: self-verdict $tok missing" >&2
        return 1
    fi
    rm -f "$log"
}

step HOVER_RIG_OK bash scripts/hover_rig.sh "$TAG" || exit 1
alive_or_die "after the hover rig"

# Path bridge: hover_gate.py reads /home/dragos/hyprvm/share/hover (the host
# view of the share). In the guest that directory is /mnt/host.
if [ ! -e /home/dragos/hyprvm/share ]; then
    mkdir -p /home/dragos/hyprvm 2>/dev/null
    ln -sfn /mnt/host /home/dragos/hyprvm/share 2>/dev/null
fi
[ -d /home/dragos/hyprvm/share/hover ] || {
    echo "FAIL: cannot reach the frames at /home/dragos/hyprvm/share/hover (grader path bridge)" >&2
    exit 1
}

python3 scripts/hover_gate.py "$TAG" || exit 1

echo "GATE hover_overshoot: PASS"
