#!/usr/bin/env bash
# y12_stash_slot_once -- a window stashed FROM the desktop you are looking at
# takes ONE grid slot, not two. See scripts/y12_rig.sh for the mechanism and
# scripts/y12_gate.py for what is graded.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

TAG=${1:-gate}

bash scripts/y12_rig.sh "$TAG" || { echo "Y12 ABORT -- rig failed"; exit 1; }
alive_or_die "after the y12 rig"
python3 scripts/y12_gate.py /mnt/host/y12 "$TAG"
