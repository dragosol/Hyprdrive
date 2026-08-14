#!/usr/bin/env bash
# X26 drag overview->dock + dock polish, end to end IN THE GUEST.
#
# Ported from the host-driven scripts/attic/x26_run.sh: the ~/hyprvm/g ssh hops
# became direct local invocations (we ARE the guest), the measurement flow is
# unchanged -- every coordinate is measured off a frame from THIS run via
# x26_points.py, because the overview tile moves with the window count and the
# dock pill is centred, so both drift between runs.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1
trap hyprwall_resume EXIT           # x26_open pauses; put the wallpaper back

SHARE=/mnt/host/x26
mkdir -p "$SHARE" || { echo "x26: cannot create $SHARE" >&2; exit 1; }

measure() { python3 "$REPO/scripts/x26_points.py" "$1" "$2"; }

bash scripts/x26_open.sh || exit 1
alive_or_die "after open"
read -r GX GY PCX PTOP < <(measure "$SHARE/open.png" points) || exit 1
[ -n "${PTOP:-}" ] || { echo "x26: could not measure grab/pill points off open.png" >&2; exit 1; }
echo "grab $GX,$GY  pill centre $PCX top $PTOP"

# The hit: drop on the pill's centre.
bash scripts/x26_drag.sh "$GX" "$GY" "$PCX" $((PTOP + 39)) dock || exit 1
alive_or_die "after the dock drop"

# The near miss: 28px above the pill's top edge, deliberately close, so a reject
# proves the pill's own bounds rather than "the cursor never went near it".
bash scripts/x26_open.sh || exit 1
read -r GX GY PCX PTOP < <(measure "$SHARE/open.png" points) || exit 1
[ -n "${PTOP:-}" ] || { echo "x26: could not re-measure points for the near miss" >&2; exit 1; }
bash scripts/x26_drag.sh "$GX" "$GY" "$PCX" $((PTOP - 28)) miss || exit 1
alive_or_die "after the near miss"

# Hover: control frame first, then the icon target measured off that same frame.
bash scripts/x26_open.sh || exit 1
bash scripts/x26_hover.sh off || exit 1
read -r ICX ICY < <(measure "$SHARE/hover_off.png" icon) || exit 1
[ -n "${ICY:-}" ] || { echo "x26: could not measure the icon target off hover_off.png" >&2; exit 1; }
echo "hover target $ICX,$ICY"
bash scripts/x26_hover.sh on "$ICX" "$ICY" || exit 1
alive_or_die "after hover"

# Grade guest-side (PIL+numpy are installed here); the gate reads its inputs
# relative to the share dir.
cd "$SHARE" && python3 "$REPO/scripts/x26_gate.py"
