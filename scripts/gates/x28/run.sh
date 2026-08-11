#!/usr/bin/env bash
# X28 dock context menu, end to end IN THE GUEST.
#
# x28_gate.py is the orchestrator AND the grader -- every click coordinate
# after the first is measured off the previous frame, so the two cannot be
# separated -- and gate pythons may not be modified. It still expects the
# HOST's layout: a ~/hyprvm/g helper that runs a command in the guest, and the
# share visible at /home/dragos/hyprvm/share. We ARE the guest, so this
# wrapper stands that layout up locally: `g` becomes "run it right here",
# share becomes a symlink to /mnt/host, and the scripts the gate invokes by
# /mnt/host path are fresh copies of the repo's (same deployment model the
# host workflow used).
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

[ -d /mnt/host ] || { echo "NEEDS-HOST: /mnt/host is not mounted -- this wrapper only runs in the guest"; exit 3; }

VMROOT=/home/dragos/hyprvm
mkdir -p "$VMROOT" 2>/dev/null \
    || { echo "NEEDS-HOST: cannot create $VMROOT (x28_gate.py hardcodes it)"; exit 3; }
if [ -e "$VMROOT/share" ] && [ ! -L "$VMROOT/share" ]; then
    echo "NEEDS-HOST: $VMROOT/share is a real directory -- refusing to replace it"; exit 3
fi
ln -sfn /mnt/host "$VMROOT/share" || { echo "NEEDS-HOST: cannot symlink $VMROOT/share"; exit 3; }
printf '#!/usr/bin/env bash\n# guest-side stand-in for the host ssh helper: we are already the guest.\nexec bash -c "$1"\n' > "$VMROOT/g"
chmod +x "$VMROOT/g"

# The gate drives these by their /mnt/host paths; deploy fresh copies from the
# repo, plus the lib their `source "$(dirname "$0")/lib/rig.sh"` resolves to.
mkdir -p /mnt/host/lib || exit 1
# `cp -f`, not `cp`: /mnt/host is virtiofs with an id map, so a file the HOST
# wrote is owned by root in here and plain cp -- which truncates the existing
# inode rather than unlinking it -- gets EPERM even though the directory is
# 0777. That is the whole of this gate's "FAIL in 0s": it died staging a
# helper before it had measured anything (2026-08-11, zrig/gatefire/).
cp -f scripts/lib/rig.sh /mnt/host/lib/rig.sh || exit 1
cp -f scripts/x28_fixture.sh scripts/x28_click_at.sh /mnt/host/ || exit 1
cp -f scripts/x28_cell.py /mnt/host/x28_cell.py || exit 1

# Headless output for the whole gate: the fixture used to build it itself, but
# rig.sh's headless_on installs an EXIT-trap swap-back, so it must live in THE
# process that spans fixture, clicks and grading -- this one. RIG_MON is
# exported and reaches the fixture through x28_gate.py's environment.
hyprwall_pause
headless_on || exit 1
trap 'headless_off; hyprwall_resume' EXIT

python3 scripts/x28_gate.py
