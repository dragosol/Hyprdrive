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

# THE FIXTURE HAS TO HAVE AN ICON, and MARK does not. The hop moves the icon's
# draw box and only that -- the running dot and the badge stay put on purpose
# (Dock.cpp:3284) -- and the dock draws an icon only for a class AppSearch can
# resolve to a desktop entry. `kitty --class MARK` resolves to nothing, so
# MARK's dock cell is an empty square with a dot under it, and every "the pill
# never moved" this gate has ever printed (peak 43, 20, and 0 px over three
# rounds) was a photograph of a cell with nothing in it to move. The fixture is
# therefore spawned as `kitty`, which resolves through kitty.desktop, and the
# precondition is asserted here rather than assumed.
export Z3_MARK_CLASS=${Z3_MARK_CLASS:-kitty}
export Y8_CLASS=$Z3_MARK_CLASS

echo "=== setup ==="
if ! python3 scripts/y8_icon_check.py "$Y8_CLASS"; then
    echo "Y8 RIG FAULT: the fixture class owns no dock icon, so the hop has no moving"
    echo "part and the band would read zero whatever the bounce does. This is a"
    echo "statement about the fixture, not about the plugin."
    exit 1
fi
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
