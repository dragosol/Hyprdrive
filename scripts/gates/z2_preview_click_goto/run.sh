#!/usr/bin/env bash
# z2_preview_click_goto -- guest-side orchestrator.
# DoD Z2 (user report 2026-08-07): clicking the dock preview goes to that
# window -- view lands on its desktop AND it is focused; a control click at the
# same height but off the plate must NOT activate (no fall-through pass).
# The rig is fully self-verdicting (prints "Z2 PASS"/"Z2 FAIL" and exits
# accordingly); we require BOTH the exit code and the printed verdict.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

# z2_rig.sh predicts the icon/panel from the x47 cell model at /mnt/host.
cp scripts/x47_cell.py /mnt/host/ \
    || { echo "z2: cannot stage x47_cell.py on the share" >&2; exit 1; }

OUTPUT=$(bash scripts/z2_rig.sh gate 2>&1); RC=$?
printf '%s\n' "$OUTPUT"
alive_or_die "after the z2 rig"

[ "$RC" -eq 0 ] || exit 1
printf '%s\n' "$OUTPUT" | grep -q 'Z2 PASS' || exit 1
exit 0
