#!/usr/bin/env bash
# Phase 7 A/B. Runs IN THE GUEST. Drives the search through five settled states
# and snapshots (a) the layout dump and (b) the frame, so two builds can be
# compared field-for-field and pixel-for-pixel.
#
# THE DUMP NEEDS A TEMPORARY PATCH. /tmp/p7dump.log is written by throwaway
# instrumentation in renderSearch -- the pill box, both published heights, the
# dock progress, the measured card transform, every card box and reveal alpha,
# every hit box and the pill label, once per frame. That patch is deliberately
# NOT committed (it opens a file from the render path). Without it the .block
# files come out EMPTY and only the .png half of this rig means anything; the
# method and the numbers it produced are in /mnt/host/zrig/phase7/AB_RESULT.md.
#
# The dump is written every frame; only the LAST block of each rest point is
# taken, because the eased frames in between depend on wall-clock timing and
# cannot be identical across two separate runs of the compositor.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
TAG=${1:?usage: p7_ab.sh <parent|child>}
OUT=/mnt/host/zrig/phase7/$TAG
rm -rf "$OUT"; mkdir -p "$OUT"
MON=$(cat /mnt/host/x48/mon)
DUMP=/tmp/p7dump.log

block() { # last FRAME block of the dump -> $OUT/$1.block
    python3 - "$DUMP" "$OUT/$1.block" <<'PY'
import sys
try:
    t = open(sys.argv[1]).read()
except FileNotFoundError:
    t = ""
i = t.rfind("FRAME\n")
open(sys.argv[2], "w").write("" if i < 0 else t[i:])
PY
}
shot() { grim -o "$MON" "$OUT/$1.png"; }

ov off; sleep 1.2
ov on;  sleep 3.0
block A-rest;  shot A-rest
sleep 1.2
shot A-rest2                 # control: two idle frames, same state

key $K_K;   sleep 4.0        # query "k": apps grid + whatever providers answer
block B-query; shot B-query

key $K_TAB; sleep 2.0        # selection -1 -> 0, the opaque accent row
block C-tab;  shot C-tab

key $K_X;   sleep 4.0        # "kx": a DIFFERENT result set -- the liveness control
block D-kx;   shot D-kx

key $K_ESC; sleep 3.0        # query cleared, band eases shut
block E-clear; shot E-clear
ov off

cp "$DUMP" "$OUT/full.dump" 2>/dev/null
ls -la "$OUT" | tail -14
echo P7_AB_OK
