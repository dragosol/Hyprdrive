#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC §13.4 G5 -- TWO RESULT LAYOUTS, WITH PER-PROVIDER CAPS.
# Runs IN THE GUEST on the fixture x48_rig.sh already placed. Grades on the
# HOST with g5_gate.py (the guest has no numpy/PIL).
#
# Two claims, two locators, and they need DIFFERENT measurements:
#
#   CAPS   the cap is 6 apps + 5 rows PER PROVIDER, not 5 shared. Counted by
#          TAB-walking further than the old shared cap could reach and counting
#          DISTINCT selection boxes. On the parent the walk cannot produce more
#          than five, however many things matched.
#   GRID   apps draw as icon CELLS, not rows. A cell is ~132x78 logical where a
#          row is ~1664x34 -- so the discriminator is that at least one
#          selection is NARROW AND TALL. Every selection on the parent is a
#          wide short row.
#
# The query is "k" ON PURPOSE and it is the whole point of the fixture: "k"
# matches five or more apps, which under the old SHARED cap of 5 starved every
# provider and left exactly one section. That is the case X49 could not show.
#
# TAB, never DOWN: DOWN goes to moveSelection() and walks the GRID's tile
# selection (scrollOverview.cpp:2413). Only Tab walks the results.
set -u
source "$(dirname "$0")/lib/rig.sh"   # env discovery, ov/key, K_ESC/K_TAB/K_K
rig_env || exit 1
SRC=/mnt/host/x48; OUT=/mnt/host/g5; mkdir -p $OUT

STEPS=10
TAG=${1:?usage: g5_rig.sh <tag>}
MON=$(cat $SRC/mon)
shot() { grim -o "$MON" "$OUT/$TAG-$1.png"; }

systemctl --user stop hyprwall.timer 2>/dev/null

ov off; sleep 1.0
ov on;  sleep 2.5

# a0/a1 bracket the resting state: identical to each other, or the output is
# drifting and no diff below means anything.
shot 00-a0; sleep 1.2; shot 01-a1

key $K_K
sleep 3.0                # G7 debounce, then the provider's own round trip

for i in $(seq 1 $STEPS); do
    key $K_TAB; sleep 0.9
    shot "$(printf '1%02d-t%02d' "$i" "$i")"
done

key $K_ESC; sleep 1.5
ov off
systemctl --user start hyprwall.timer 2>/dev/null

ls -la $OUT/$TAG-*.png
md5sum $OUT/$TAG-*.png | awk '{print $1}' | sort -u | wc -l | xargs echo "distinct frames:"
echo G5_RUN_OK
