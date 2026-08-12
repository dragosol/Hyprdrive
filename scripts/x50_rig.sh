#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC §13.12 X50 -- THE SEARCH BAR ANIMATES UP WHEN RESULTS APPEAR.
# Runs IN THE GUEST on the fixture x48_rig.sh already placed (headless output,
# two kitty windows on workspace 1). Grades on the HOST with x50_gate.py.
#
# The claim has a POSITIVE and a NEGATIVE half and the negative one is what
# stops this passing on a build that simply moved the pill up unconditionally:
#
#   DOCK    query "k" matches apps AND both fixtures, so results populate: the
#           pill must appear in the band just under the work area's top edge,
#           and must vanish from where it rested.
#   NOMATCH query "zqxjw" matches nothing anywhere. The pill still WIDENS (the
#           field goes 210 -> 360 logical on any keystroke), so this frame is
#           NOT identical to rest -- but nothing may change in the top band.
#           A build that docks on the first keystroke fails here and only here.
#   CLEAR   Esc returns the pill to rest, so the top band is empty again.
#
# a0/a1 bracket the resting state: if those two differ the output is drifting
# and no later diff means anything.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
SRC=/mnt/host/x48; OUT=/mnt/host/x50; mkdir -p $OUT

# ov()/key() come from lib/rig.sh (verbatim-equivalent to the old local ones).
K_ESC=1; K_K=37; K_Z=44; K_Q=16; K_X=45; K_J=36; K_W=17

TAG=${1:?usage: x50_rig.sh <tag>}
MON=$(cat $SRC/mon)
shot() { grim -o "$MON" "$OUT/$TAG-$1.png"; }

hyprwall_pause         # a stop under a suite, a dead-man on its own

hyprctl monitors -j > $OUT/monitors.json
hyprctl layers -j   > $OUT/layers.json

ov off; sleep 1.0
ov on;  sleep 2.5

shot 00-a0; sleep 1.2; shot 01-a1

# DOCK: "k" matches the KRED/KBLU fixtures and several apps.
key $K_K
sleep 3.0                # G7 debounce, then the provider round trip, then the ease
shot 10-dock

key $K_ESC; sleep 2.0    # clear
shot 20-clear

# NOMATCH: "zqxjw". Measured 2026-08-06: "zq" is NOT a no-match query -- the
# Characters provider answers it with the Syriac Zqapha block, the pill docked,
# and the control was really a second positive case. Five letters, chosen so no
# provider and no app name contains them in order.
key $K_Z; key $K_Q; key $K_X; key $K_J; key $K_W
sleep 3.0
shot 30-nomatch

key $K_ESC; sleep 1.5
ov off
hyprwall_resume        # the suite's hold applies here too

ls -la $OUT/$TAG-*.png
md5sum $OUT/$TAG-*.png | awk '{print $1}' | sort -u | wc -l | xargs echo "distinct frames:"
echo X50_RUN_OK
