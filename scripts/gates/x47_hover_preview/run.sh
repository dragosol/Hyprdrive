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

echo "== x47 sharp arm (fa)"
X47_STRIPES=1 X47_BLUR='blur_size=1, blur_passes=1' bash scripts/x47_rig.sh fa \
    || { echo "X47: sharp arm failed"; exit 1; }
alive_or_die "after the sharp arm"

echo "== x47 frosted arm (fb)"
X47_STRIPES=1 X47_BLUR='blur_size=20, blur_passes=4' bash scripts/x47_rig.sh fb \
    || { echo "X47: frosted arm failed"; exit 1; }
alive_or_die "after the frosted arm"

echo "== x47_gate (on the frosted arm's frames)"
python3 scripts/x47_gate.py fb || exit 1

echo "== x47_frost fa fb"
python3 scripts/x47_frost.py fa fb || exit 1

echo X47_GATE_GREEN
exit 0
