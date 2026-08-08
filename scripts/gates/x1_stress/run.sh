#!/usr/bin/env bash
# x1_stress gate -- spec 13.4 X1: many windows, heavy filtering, rapid desktop
# switching; must not fall over, LEAK, or CORRUPT STATE.
# Order: x1_fixture.sh 24 3 (headless output + 24 kitty tiles over 3 ws), then
# the self-verdicting stress run. Green iff x1_stress.sh exits 0 AND prints
# X1_STRESS_VERDICT PASS. No separate grader -- the rig grades itself.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

# The fixture deliberately leaves the headless output alive (and Virtual-1
# disabled) for the stress run, so no script below owns the swap-back -- the
# wrapper does. RIG_HEADLESS=1 arms rig.sh's idempotent teardown; the resume
# is also armed as a systemd dead-man by the fixture's hyprwall_pause, this
# trap just makes it immediate.
cleanup() { RIG_HEADLESS=1; headless_off; hyprwall_resume; }
trap cleanup EXIT

bash scripts/x1_fixture.sh 24 3 || { echo "x1_stress gate: fixture failed" >&2; exit 1; }

LOG=/mnt/host/x1/x1-stress-run.log
mkdir -p /mnt/host/x1
bash scripts/x1_stress.sh 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || exit "$rc"
grep -q 'X1_STRESS_VERDICT PASS' "$LOG"
