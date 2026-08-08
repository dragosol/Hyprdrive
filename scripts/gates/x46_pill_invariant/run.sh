#!/usr/bin/env bash
# Gate x46_pill_invariant -- OVERVIEW_CPP_SPEC 13.12 X46: a minimize must not
# add a dock entry; the strip band is pixel-identical (pill extent unchanged)
# before/after a minimize, and the rig ABORTs (never passes) if nothing
# actually minimized. GUEST-side: rig captures -> x46_gate.py grades.
# Exit 0 iff green.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

TAG=${1:-suite}

# x46_gate.py hardcodes the HOST's view of the share (/home/dragos/hyprvm/share);
# grading now runs in the guest, where the share is /mnt/host. Alias, never edit
# the grader.
if [ ! -e /home/dragos/hyprvm/share ]; then
    mkdir -p /home/dragos/hyprvm
    ln -sfn /mnt/host /home/dragos/hyprvm/share || exit 1
fi

hyprwall_pause
# The gate's stall check (idle drift) is reported as context, not gated on, so
# stale frames from a detached Virtual-1 would make "nothing moved" pass
# trivially -- the strip captures must come from a live headless output.
headless_on || exit 1
trap 'headless_off; hyprwall_resume' EXIT

bash scripts/x46_rig.sh "$TAG" || { echo "X46: rig failed/aborted"; exit 1; }
alive_or_die "after the rig"

python3 scripts/x46_gate.py "$TAG" || exit 1

echo X46_GATE_GREEN
exit 0
