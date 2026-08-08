#!/usr/bin/env bash
# X30 dock autohide/reveal, end to end IN THE GUEST: rig phases in order, then
# the grader. Phase order matters -- `leave` measures re-hide after `strong`'s
# reveal -- and `slide` is required by the gate's P6 even though the old
# host-side runbook forgot to list it.
#
# x30_gate.py may not be modified and reads /home/dragos/hyprvm/share/x30 (the
# HOST's view of the share); stand that path up locally as a symlink to
# /mnt/host and grade right here (PIL+numpy are installed in the guest).
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1
trap hyprwall_resume EXIT           # the fixture phase pauses; put it back

[ -d /mnt/host ] || { echo "NEEDS-HOST: /mnt/host is not mounted -- this wrapper only runs in the guest"; exit 3; }

VMROOT=/home/dragos/hyprvm
mkdir -p "$VMROOT" 2>/dev/null \
    || { echo "NEEDS-HOST: cannot create $VMROOT (x30_gate.py hardcodes it)"; exit 3; }
if [ -e "$VMROOT/share" ] && [ ! -L "$VMROOT/share" ]; then
    echo "NEEDS-HOST: $VMROOT/share is a real directory -- refusing to replace it"; exit 3
fi
ln -sfn /mnt/host "$VMROOT/share" || { echo "NEEDS-HOST: cannot symlink $VMROOT/share"; exit 3; }

phase() { # phase NAME OK_TOKEN
    local out rc
    out=$(bash scripts/x30_rig.sh "$1" 2>&1); rc=$?
    printf '%s\n' "$out"
    [ "$rc" = 0 ] || { echo "x30: phase $1 exited $rc" >&2; exit 1; }
    grep -q "$2" <<< "$out" || { echo "x30: phase $1 did not report $2" >&2; exit 1; }
    alive_or_die "after phase $1"
}

phase fixture    X30_FIXTURE
phase base       BASE_OK
phase fixed      FIXED_OK
phase weak       WEAK_OK
phase lowthresh  LOWTHRESH_OK
phase strong     STRONG_OK
phase leave      LEAVE_OK
phase overview   OVERVIEW_OK
phase fullscreen FULLSCREEN_OK
phase slide      SLIDE_OK

python3 scripts/x30_gate.py
