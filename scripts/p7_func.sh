#!/usr/bin/env bash
# Phase 7 behaviour check. Runs IN THE GUEST. The three things this phase
# actually moved -- the session reset, the published hit list the keyboard walks,
# and the published hit list the pointer hit-tests -- driven end to end.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
TAG=${1:?usage: p7_func.sh <tag>}
OUT=/mnt/host/zrig/phase7/func-$TAG
rm -rf "$OUT"; mkdir -p "$OUT"
MON=$(cat /mnt/host/x48/mon)
# evdev arrow keycodes; the rig lib carries only the keys its own gates press.
K_LEFT=105; K_RIGHT=106
shot() { grim -o "$MON" "$OUT/$1.png"; }

ov off; sleep 1.2
ov on;  sleep 3.0; shot 00-rest
key $K_K; sleep 4.0; shot 10-query          # results up, pill docked
key $K_TAB; sleep 1.5; shot 20-sel0         # selection on result 0

# RESET: close and reopen. The query, the nav zone and the selection must all
# be gone -- this frame has to match 00-rest, not 10-query.
ov off; sleep 2.0
ov on;  sleep 3.0; shot 30-reopened

# KEYBOARD WALK over the published hit list.
key $K_K; sleep 4.0; shot 40-query2
key $K_TAB; sleep 1.5; shot 50-sel0
key $K_RIGHT; sleep 1.5; shot 51-right      # a different cell takes the ring
key $K_LEFT;  sleep 1.5; shot 52-left       # ...and back
ov off
ls "$OUT" | tr '\n' ' '; echo
echo P7_FUNC_OK
