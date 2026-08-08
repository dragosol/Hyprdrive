#!/usr/bin/env bash
# GATE reopen -- a tap DURING the close animation (120ms into ~300ms) brings
# the overview back. Guest-side: reopen_rig.sh fixture (two kitties) then run
# (open/shut/open2/reversed frames to /mnt/host/reopenshots), reopen_gate.py
# grades them here. The grader hardcodes the HOST share path, so we bridge it
# with a symlink instead of editing the grader.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

hyprwall_pause                       # the fixture re-pauses with its own 40min dead-man
trap 'pkill -x kitty 2>/dev/null; hyprwall_resume' EXIT

step() { # step TOKEN CMD... -- run, echo through, require the self-verdict
    local tok=$1; shift
    local log; log=$(mktemp)
    "$@" 2>&1 | tee "$log"
    if ! grep -q "$tok" "$log"; then
        rm -f "$log"
        echo "GATE reopen: self-verdict $tok missing" >&2
        return 1
    fi
    rm -f "$log"
}

step "FIXTURE clients="  bash scripts/reopen_rig.sh fixture || exit 1
step "REOPEN rig done"   bash scripts/reopen_rig.sh run     || exit 1
alive_or_die "after the reopen rig"

# Path bridge: reopen_gate.py reads /home/dragos/hyprvm/share/reopenshots (the
# host view of the share). In the guest that directory is /mnt/host.
if [ ! -e /home/dragos/hyprvm/share ]; then
    mkdir -p /home/dragos/hyprvm 2>/dev/null
    ln -sfn /mnt/host /home/dragos/hyprvm/share 2>/dev/null
fi
[ -d /home/dragos/hyprvm/share/reopenshots ] || {
    echo "FAIL: cannot reach the frames at /home/dragos/hyprvm/share/reopenshots (grader path bridge)" >&2
    exit 1
}

python3 scripts/reopen_gate.py || exit 1

echo "GATE reopen: PASS"
