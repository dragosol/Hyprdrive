#!/usr/bin/env bash
# OWN-SIZE TILES gate (OwnSizeTile.hpp; user, 2026-11-10: "super+t should toggle
# between tiling fixed-size windows at their own size and floating").
#
# In the headless rig (scripts/headless/hl.sh, XWayland on): insist.py is an X11
# window of a fixed 362x677 that asks for that size again on every
# ConfigureNotify, as Wine's Battle.net login does. For dwindle, scrolling and
# Mosaic it checks Super+T tiles it at EXACTLY its size with no configure storm
# (the bug: ~1765/s on Mosaic, dwindle refusing it), Super+T floats it back, a
# crowded desktop overflows instead of squeezing it, a size change of its own is
# followed, and an unloaded plugin leaves it floating. Exit status = failures.
#
#   scripts/gates/own_size_tile/run.sh [path/to/hyprdrive.so]
set -u
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
H=$ROOT/scripts/headless/hl.sh
SO=${1:-$ROOT/hyprdrive.so}
export HL_NAME=ownsize
SHARE=$(mktemp -d /tmp/hd-ownsize.XXXX); chmod 755 "$SHARE"
cp "$(dirname "$0")/insist.py" "$SHARE/insist.py"; chmod 644 "$SHARE/insist.py"
OUT=/tmp/hl-$HL_NAME/insist.txt
fails=0
check() { if [ "$2" = 1 ]; then echo "ok   $1"; else echo "FAIL $1 ($3)"; fails=$((fails + 1)); fi; }
state() { $H h clients -j | python3 -c "
import json,sys
c = next((c for c in json.load(sys.stdin) if c['class']=='hdtest.insist'), None)
print('none' if not c else '%dx%d %s' % (c['size'][0], c['size'][1], 'FLOAT' if c['floating'] else 'TILED'))"; }
start() {
    $H stop >/dev/null 2>&1
    $H start --so "$SO" >/dev/null 2>&1 || { echo "FAIL rig start"; exit 99; }
    $H eval "hl.config({general={layout=\"$1\"}, misc={size_limits_tiled=true}})" >/dev/null
    $H eval 'hl.bind("SUPER + T", hl.dsp.window.float({ action = "toggle" }))' >/dev/null
}
others() { for n in $(seq 1 "$1"); do $H eval "hl.dispatch(hl.dsp.exec_cmd(\"kitty --class hdtest.c$n --title c$n\"))" >/dev/null; sleep 0.9; done; }
insist() { # SECONDS [GROW_AT]
    $H eval "hl.dispatch(hl.dsp.exec_cmd(\"python3 $SHARE/insist.py 362 677 $1 $OUT ${2:-}\"))" >/dev/null
    for _ in $(seq 1 30); do $H h clients -j | grep -q '"class": "hdtest.insist"' && break; sleep 0.3; done
    sleep 1.5
    A=$($H h clients -j | python3 -c "import json,sys; print(next(c['address'] for c in json.load(sys.stdin) if c['class']=='hdtest.insist'))")
    $H eval "hl.dispatch(hl.dsp.focus({ window = [[address:$A]] }))" >/dev/null; sleep 0.2
}
storm() { # FROM TO: the most ConfigureNotify in one second of that span
    python3 -c "
import re,sys
n=[int(m.group(2)) for m in re.finditer(r't=\s*(\d+)s configure=\s*(\d+)', open('$OUT').read()) if $1 <= int(m.group(1)) <= $2]
print(max(n) if n else -1)"; }

for L in dwindle scrolling mosaic; do
    start $L; others 1; insist 10
    $H tap Super+T; sleep 0.8; S1=$(state); sleep 4; $H tap Super+T; sleep 0.8; S2=$(state); sleep 4.5
    check "$L: Super+T tiles it at its own size" "$([ "$S1" = '362x677 TILED' ] && echo 1)" "$S1"
    check "$L: no configure storm while tiled" "$([ "$(storm 3 6)" -le 5 ] && echo 1)" "$(storm 3 6)/s"
    check "$L: Super+T floats it back at its size" "$([ "$S2" = '362x677 FLOAT' ] && echo 1)" "$S2"
done
for L in dwindle mosaic; do
    start $L; others 6; insist 8
    $H tap Super+T; sleep 0.8; S1=$(state); sleep 6.5
    check "$L, crowded: still its own size (overflows, not squeezed)" "$([ "$S1" = '362x677 TILED' ] && echo 1)" "$S1"
    check "$L, crowded: no configure storm" "$([ "$(storm 3 7)" -le 5 ] && echo 1)" "$(storm 3 7)/s"
done
start mosaic; others 1; insist 10 5
$H tap Super+T; sleep 4.5; S1=$(state); sleep 5
check "mosaic: a size change of its own is followed" "$([ "$S1" = '462x727 TILED' ] && echo 1)" "$S1"
check "mosaic: no storm after it changes size" "$([ "$(storm 6 9)" -le 5 ] && echo 1)" "$(storm 6 9)/s"
start dwindle; others 1; insist 8
$H tap Super+T; sleep 1
$H h plugin unload "/tmp/hl-$HL_NAME/staged/hyprdrive.so" >/dev/null 2>&1; sleep 0.8; S1=$(state); sleep 5
check "unloaded while tiled: left floating at its size" "$([ "$S1" = '362x677 FLOAT' ] && echo 1)" "$S1"
check "unloaded while tiled: no storm after" "$([ "$(storm 4 7)" -le 5 ] && echo 1)" "$(storm 4 7)/s"

$H stop >/dev/null 2>&1
rm -rf "$SHARE"
echo "own_size_tile gate: $fails failed"
exit "$fails"
