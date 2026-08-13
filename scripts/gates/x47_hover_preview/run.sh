#!/usr/bin/env bash
# Gate x47_hover_preview -- OVERVIEW_CPP_SPEC 13.12 X47: hovering a dock icon
# raises a LIVE preview panel (RISES/LIVE/FOLLOWS/GRACE, controls both sides,
# dilated noise mask, largest blob where x47_cell.py predicts), plus the FROST
# A/B (sharp 1/1 vs frosted 20/4 over an identical striped fixture; SAMEBACK
# asserts a bit-identical backdrop). GUEST-side, end to end. Exit 0 iff green.
#
# The rig owns its own hyprwall pause, headless swap and chained restore trap,
# so this wrapper stays thin: two rig arms, then the two graders.
# The main gate is graded on the frosted arm's frames -- the four claims it
# grades do not read the blur keys, and a third default-config run would push
# the gate well past its ~3-4 min budget.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

# The graders hardcode the HOST's view of the share (/home/dragos/hyprvm/share);
# grading now runs in the guest, where the share is /mnt/host. Alias, never edit
# the graders.
if [ ! -e /home/dragos/hyprvm/share ]; then
    mkdir -p /home/dragos/hyprvm
    ln -sfn /mnt/host /home/dragos/hyprvm/share || exit 1
fi

# THE PLATE'S BACKDROP IS NOT WHAT THE GATE THOUGHT IT WAS, TWICE.
#
# x47_rig.sh's own comment said the backdrop "in this band is the desktop-strip
# minis of these very windows", which is why every attempt at the TEXTURE
# precondition went to the fixture's stripes. It is not. Measured 2026-08-13
# (zrig/danglingC/x47-band.log): the plate sits at y 1354..1506 and every
# X47A/X47B window is at [730,450] 1100x700 -- 200px above it and not under it
# at all. That is why one-row stripes scored HF-y 1.02 and five-row bands scored
# 0.50: neither was ever in frame.
#
# Nor is it the wallpaper. A generated two-scale image was pinned for both arms
# and the plate's backdrop did not move a pixel (identical TEXTURE numbers on
# two different generated images, one of which was not even applied) -- quickshell
# paints its wallpaper on Virtual-1, and these arms run on a HEADLESS output.
# What IS behind the plate is the compositor's own background: flat at luminance
# ~22 with one hard edge across the top rows (144 -> 4).
#
# So the frost is graded on the structure that is REALLY there, per the pattern
# x64's frost check was regraded to in round B -- fine detail GONE, coarse shape
# REMAINS -- with the two claims taken on the axes that can carry them. See the
# BACKDROP note in x47_frost.py.

# ONE run: the main gate grades RISES/LIVE/FOLLOWS/GRACE on the frosted frames,
# and X47_FROST_PAIR captures the sharp+frosted plate pair against the SAME
# frozen hover (frost-fa / frost-fb) so the frost A/B compares a bit-identical
# backdrop. Two independent runs floated the fixtures apart and broke SAMEBACK.
echo "== x47 run (frosted main + frost A/B pair)"
X47_STRIPES=1 X47_FROST_PAIR=1 X47_BLUR='blur_size=20, blur_passes=4' bash scripts/x47_rig.sh fb \
    || { echo "X47: run failed"; exit 1; }
alive_or_die "after the run"

echo "== x47_gate (on the frosted run's frames)"
python3 scripts/x47_gate.py fb || exit 1

echo "== x47_frost frost-fa frost-fb"
python3 scripts/x47_frost.py frost-fa frost-fb || exit 1

echo X47_GATE_GREEN
exit 0
