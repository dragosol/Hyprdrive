#!/usr/bin/env bash
# X50 second half: the pill MOVES, it does not cut. Spec says "animate-move".
#
# The query is "k" because both fixture windows match it SYNCHRONOUSLY -- the
# window-match half of the trigger needs no debounce and no provider round
# trip, so the flight starts on the very next frame after the keypress and a
# burst of grims can land inside it. (A provider-only query would start the
# flight seconds later, at a time this script cannot predict.)
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
SRC=/mnt/host/x48; OUT=/mnt/host/x50; mkdir -p $OUT
MON=$(cat $SRC/mon)
TAG=${1:?usage: x50_flight.sh <tag>}

# ov() comes from lib/rig.sh (verbatim-equivalent to the old local one). The
# raw `ydotool key` below stays raw ON PURPOSE: rig.sh key() sleeps 0.30 after
# the press, and the grim burst must start on the very next line.

hyprwall_pause         # a stop under a suite, a dead-man on its own
ov off; sleep 1.0
ov on;  sleep 2.5
grim -o "$MON" "$OUT/$TAG-f00-rest.png"

ydotool key 37:1 37:0
for i in $(seq 1 6); do grim -o "$MON" "$OUT/$TAG-f$(printf '%02d' "$i").png"; done
sleep 2.5
grim -o "$MON" "$OUT/$TAG-f99-settled.png"

ydotool key 1:1 1:0; sleep 1.0
ov off
hyprwall_resume        # the suite's hold applies here too
ls -la $OUT/$TAG-f*.png
echo X50_FLIGHT_OK
