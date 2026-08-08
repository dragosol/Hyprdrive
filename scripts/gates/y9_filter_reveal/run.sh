#!/usr/bin/env bash
# Y9 gate (as revised 2026-08-06): minimized windows show in the overview ONLY
# when a query matches -- q0 no-query magenta ABSENT, q1 "MAGWIN" magenta
# PRESENT, q2 cleared magenta ABSENT again. q2 kills the always-show cheat;
# the green fixture is the typing-liveness control.
#
# Rig runs guest-side, grader runs here too (PIL+numpy live in the guest);
# frames stay on the share at /mnt/host/y9.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

TAG=${1:-gate}

bash scripts/y9_rig.sh "$TAG" || { echo "Y9 ABORT -- rig failed"; exit 1; }
python3 scripts/y9_gate.py /mnt/host/y9 "$TAG"
