#!/usr/bin/env bash
# z1_preview_survives_swaps -- guest-side orchestrator.
# DoD Z1 (user report 2026-08-07): move a window to another desktop, hover its
# dock preview, swap desktops back and forth -- the preview must still draw
# (h0 == h1, both bracketed by unhovered controls c0/c1).
#   fixture+rig: scripts/z1_rig.sh  (captures to /mnt/host/z1)
#   grade:       scripts/z1_gate.py (PIL+numpy run here in the guest; exit 2 =
#                inconclusive rig, which is a FAIL, not a pass)
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

TAG=gate

# z1_rig.sh predicts the icon/panel from the x47 cell model at /mnt/host.
cp scripts/x47_cell.py /mnt/host/ \
    || { echo "z1: cannot stage x47_cell.py on the share" >&2; exit 1; }

bash scripts/z1_rig.sh "$TAG" || exit 1
alive_or_die "after the z1 rig"

python3 scripts/z1_gate.py /mnt/host/z1 "$TAG"
