#!/usr/bin/env bash
# Y11 gate (the regression gate on X99): a non-active-desktop dock preview is
# NON-BLANK (fixture magenta in the panel band) and LIVE (changed pixels
# between two hover frames, inside the found cell), with the desktop swapped
# back and forth BEFORE measuring (Z1's m_renderOffset trap) and this run's own
# c0/c1 noise floor.
#
# Rig runs guest-side, grader runs here too (PIL+numpy live in the guest);
# frames stay on the share at /mnt/host/y11.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

TAG=${1:-gate}

# The rig aims with the /mnt/host copy of the cell predictor; the repo copy is
# canonical, so place it there when missing or stale.
ensure_share() {
    cmp -s "scripts/$1" "/mnt/host/$1" 2>/dev/null && return 0
    cp -f "scripts/$1" "/mnt/host/$1" \
        || { echo "NEEDS-HOST: cannot place scripts/$1 at /mnt/host -- share not mounted?" >&2; return 1; }
}
ensure_share x47_cell.py || exit 3

bash scripts/y11_rig.sh "$TAG" || { echo "Y11 ABORT -- rig failed"; exit 1; }
python3 scripts/y11_gate.py /mnt/host/y11 "$TAG"
