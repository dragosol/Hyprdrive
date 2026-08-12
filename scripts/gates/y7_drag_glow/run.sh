#!/usr/bin/env bash
# Y7 gate: dock glow intensity is CONTINUOUS in the drag's distance inside the
# bottom-30% band -- off above it, rising in steps none of which is the whole
# rise, full at the pill (13.14 Y7).
#
# Self-locating, y8_run.sh style (the audit asked for exactly that at
# promotion): z3_setup re-fixtures MARK and leaves a fresh overview frame, the
# red blob's centre is the grab point, and the probe drags it down the hard-left
# lane while grabbing one frame per rung. y7_gate.py finds the pill itself in
# rung0, so only the grab needs locating here.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

# z3_setup switches the guest onto a headless output and never switches back
# (its callers own that); flag it so headless_off tears the swap down whatever
# happens after this point -- the un-skippable-swap-back rule [x47_rig.sh:37-42].
RIG_HEADLESS=1
trap 'ov off; headless_off; hyprwall_resume' EXIT
hyprwall_pause

echo "=== setup (fresh MARK fixture + overview frame) ==="
dsp "hl.plugin.$RIG_NS.minimize([[restore]])"; sleep 2
bash scripts/z3_setup.sh || { echo "Y7 ABORT -- z3_setup failed"; exit 1; }

read -r _ TX TY _ _ _ <<< "$(python3 scripts/z3_blobs.py /mnt/host/z3/view-ws1.png red)"
case "${TX:-}" in ''|NONE) echo "Y7 ABORT -- no red tile found in the overview frame"; exit 1 ;; esac
echo "grab (MARK tile centre): $TX,$TY"

echo "=== probe ==="
bash scripts/y7_probe.sh "$TX" "$TY" || { echo "Y7 ABORT -- probe failed"; exit 1; }

echo "=== gate ==="
python3 scripts/y7_gate.py /mnt/host/y7
