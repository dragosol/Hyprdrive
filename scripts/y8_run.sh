#!/usr/bin/env bash
# Y8 driver. Host-side, because the tile and the pill have to be LOCATED before
# every run: MARK's overview tile moves whenever a previous run left it
# somewhere else, and a probe handed a remembered hit target grabs empty space
# and reports "no bounce" for a gesture that never happened. That is exactly how
# the first three attempts at this went.
#
# It also pins the wallpaper down for the whole run. hyprwall.timer rotates the
# background, and z3_setup only holds it off for thirty minutes -- long enough
# that a slow afternoon's rigs start photographing a wallpaper change and
# reading it as an animation (measured: 2148867 changed pixels, which is the
# whole screen).
#
# The hold is the GATE's now (scripts/gates/y8_bounce_once/run.sh calls
# hyprwall_pause 90min through lib/rig.sh, which honours RIG_HYPRWALL_HELD).
# This driver used to drive hyprwall.timer with raw systemctl over ssh, which
# cannot honour a suite's hold and, because the timer carries
# OnUnitActiveSec=3min, makes `start` itself a rotation. It is deleted rather
# than ported: this script is the host-side driver the gate was ported AWAY
# from, it does not run inside the suite, and nothing else in it touches the
# wallpaper.
set -u
cd "$(dirname "$0")/.."
G=./g
SHARE=./share

# A CLEAN FIXTURE, every time. z3_setup kills kitty, respawns MARK and parks it,
# so the tile is back where the locator can find it whatever the last run did.
echo "=== setup ==="
$G 'hyprctl eval "return hl.dispatch(hl.plugin.hyprdrive.minimize([[restore]]))" >/dev/null 2>&1; sleep 2; bash /mnt/host/z3_setup.sh 2>&1 | tail -1'

read -r _ TX TY _ _ _ <<< "$(python3 $SHARE/z3_blobs.py $SHARE/z3/view-ws1.png red)"
read -r PX0 PX1 PY0 PY1 <<< "$(python3 $SHARE/pillbox.py $SHARE/z3/view-ws1.png)"
PCX=$(( (PX0 + PX1) / 2 )); PCY=$(( (PY0 + PY1) / 2 ))
echo "tile centre $TX,$TY   pill $PX0..$PX1 x $PY0..$PY1  centre $PCX,$PCY"

echo "=== probe ==="
$G "Y8_FRAMES=${Y8_FRAMES:-40} Y8_GAP=${Y8_GAP:-0.22} bash /mnt/host/y8_probe.sh $TX $TY $PCX $PCY $PY0 2>&1 | tail -3"

python3 $SHARE/y8_gate.py $SHARE/y8 $PY0
