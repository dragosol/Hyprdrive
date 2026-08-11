#!/usr/bin/env bash
# x32_showapps_fresh -- guest-side orchestrator.
# X32 (orchestrator decision, 2026-08-11): a fresh open from the dock's Show
# Applications button starts CLEAN. The button is the one entry into the
# overview that did not run the dispatcher's search-session reset, so a query
# typed into a previous open survived a tile-click close and came back with it.
#   rig:   scripts/x32_rig.sh   (frames -> /mnt/host/x32)
#   grade: scripts/x32_gate.py  (also the rig's tile locator, --tile)
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

TAG=${1:-suite}

bash scripts/x32_rig.sh "$TAG" || { echo "X32 ABORT -- rig failed"; exit 1; }
alive_or_die "after the x32 rig"

python3 scripts/x32_gate.py /mnt/host/x32 "$TAG"
