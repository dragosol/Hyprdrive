#!/usr/bin/env bash
# Y8 gate: on drop-to-minimize the landing icon hops ONCE, macOS-like, "not a
# decaying bounce train" -- IT HAPPENS / ONE PEAK / IT SETTLES (13.14 Y8).
#
# Guest-side port of scripts/y8_run.sh (which drove this over ssh from the
# host). The tile and the pill are LOCATED before every run: MARK's overview
# tile moves whenever a previous run left it somewhere else, and a probe handed
# a remembered hit target grabs empty space and reports "no bounce" for a
# gesture that never happened -- the first three manual attempts, exactly.
#
# The wallpaper is pinned for 90min (longer than z3_setup's own 30min re-arm;
# see y8_run.sh's header) so a slow afternoon's runs don't photograph a
# wallpaper change and read it as an animation.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

# z3_setup switches the guest onto a headless output and never switches back;
# flag it so headless_off tears the swap down whatever happens after this point.
RIG_HEADLESS=1
trap 'headless_off; hyprwall_resume' EXIT
hyprwall_pause 90min

echo "=== setup ==="
dsp "hl.plugin.$RIG_NS.minimize([[restore]])"; sleep 2
bash scripts/z3_setup.sh || { echo "Y8 ABORT -- z3_setup failed"; exit 1; }

read -r _ TX TY _ _ _ <<< "$(python3 scripts/z3_blobs.py /mnt/host/z3/view-ws1.png red)"
case "${TX:-}" in ''|NONE) echo "Y8 ABORT -- no red tile found in the overview frame"; exit 1 ;; esac
read -r PX0 PX1 PY0 PY1 <<< "$(python3 scripts/pillbox.py /mnt/host/z3/view-ws1.png)"
[ -n "${PY1:-}" ] || { echo "Y8 ABORT -- pillbox found no pill"; exit 1; }
PCX=$(( (PX0 + PX1) / 2 )); PCY=$(( (PY0 + PY1) / 2 ))
echo "tile centre $TX,$TY   pill $PX0..$PX1 x $PY0..$PY1  centre $PCX,$PCY"

echo "=== probe ==="
Y8_FRAMES=${Y8_FRAMES:-40} Y8_GAP=${Y8_GAP:-0.22} \
    bash scripts/y8_probe.sh "$TX" "$TY" "$PCX" "$PCY" "$PY0" \
    || { echo "Y8 ABORT -- probe failed"; exit 1; }

echo "=== gate ==="
python3 scripts/y8_gate.py /mnt/host/y8 "$PY0"
