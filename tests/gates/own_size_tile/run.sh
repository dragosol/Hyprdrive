#!/usr/bin/env bash
# OWN-SIZE TILES gate (OwnSizeTile.hpp; user, 2026-11-10: "super+t should toggle
# between tiling fixed-size windows at their own size and floating").
#
# In the headless rig (tests/rig/headless/hl.sh, XWayland on): insist.py is an X11
# window of a fixed 362x677 that asks for that size again on every
# ConfigureNotify, as Wine's Battle.net login does. For dwindle, scrolling and
# Mosaic it checks Super+T tiles it at EXACTLY its size with no configure storm
# (the bug: ~1765/s on Mosaic, dwindle refusing it), Super+T floats it back, a
# crowded desktop overflows instead of squeezing it, a size change of its own is
# followed, and an unloaded plugin leaves it floating. With misc:size_limits_tiled
# OFF, as Hyprland ships it: 20-layout.lua turned it on for this, and under it
# every tiled window is clamped into the screen -- it piled the infinite
# canvas's windows up (user, 2026-11-10: "you broke it"); the canvas check runs
# it once more as the control that must fail. Exit status = failures.
#
#   tests/gates/own_size_tile/run.sh [path/to/hyprdrive.so]
set -u
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
H=$ROOT/tests/rig/headless/hl.sh
SO=${1:-$ROOT/hyprdrive.so}
export HL_NAME=${HL_NAME:-ownsize}  # the gate runner passes gown
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
    $H eval "hl.config({general={layout=\"$1\"}})" >/dev/null
    $H eval 'hl.bind("SUPER + T", hl.dsp.window.float({ action = "toggle" }))' >/dev/null
}
monitor() { $H h monitors -j > "$SHARE/mon.json"; }
where() { # the insist window inside the screen: on, or off and where
    monitor; $H h clients -j | python3 -c "
import json,sys
m = json.load(open('$SHARE/mon.json'))[0]; W, H = m['width'] / m['scale'], m['height'] / m['scale']
c = next((c for c in json.load(sys.stdin) if c['class']=='hdtest.insist'), None)
x, y, w, h = (c['at'] + c['size']) if c else (0, 0, 0, 0)
print('none' if not c else 'on' if x >= 0 and y >= 0 and x + w <= W and y + h <= H else 'off %d,%d %dx%d' % (x, y, w, h))"; }
canvas() { # the tiled hdtest.c* windows: how many lie past the screen, how many pairs overlap, how many there are
    monitor; $H h clients -j | python3 -c "
import json,sys
m = json.load(open('$SHARE/mon.json'))[0]; W, H = m['width'] / m['scale'], m['height'] / m['scale']
t = [c for c in json.load(sys.stdin) if c['class'].startswith('hdtest.c') and not c['floating']]
past = sum(1 for c in t if c['at'][0] < 0 or c['at'][1] < 0 or c['at'][0] + c['size'][0] > W + 1 or c['at'][1] + c['size'][1] > H + 1)
over = lambda a, b, i: min(a['at'][i] + a['size'][i], b['at'][i] + b['size'][i]) - max(a['at'][i], b['at'][i]) > 2
print(past, sum(1 for i in range(len(t)) for j in range(i + 1, len(t)) if over(t[i], t[j], 0) and over(t[i], t[j], 1)), len(t))"; }
# N kitty windows, each 1200x800 to start with -- never the size the last one
# closed at (kitty remembers it, so a crowded run's small tiles made the next
# run's canvas fit the screen and never spill).
others() { for n in $(seq 1 "$1"); do $H eval "hl.dispatch(hl.dsp.exec_cmd(\"kitty --class hdtest.c$n --title c$n -o remember_window_size=no -o initial_window_width=1200 -o initial_window_height=800\"))" >/dev/null; sleep 0.9; done; }
insist() { # SECONDS [GROW_AT]
    $H eval "hl.dispatch(hl.dsp.exec_cmd(\"python3 $SHARE/insist.py 362 677 $1 $OUT ${2:-}\"))" >/dev/null
    for _ in $(seq 1 30); do $H h clients -j | grep -q '"class": "hdtest.insist"' && break; sleep 0.3; done
    sleep 1.5
    A=$($H h clients -j | python3 -c "import json,sys; print(next(c['address'] for c in json.load(sys.stdin) if c['class']=='hdtest.insist'))")
    $H eval "hl.dispatch(hl.dsp.focus({ window = [[address:$A]] }))" >/dev/null; sleep 0.2
}
# ON MOSAIC IT OPENS TILED (the enforcer, WindowPlacement.cpp: a fixed-size
# window tiles at its own size as it maps); floated first by Super+T there, so
# every layout's steps below start from the same floating window.
float_first() { # LAYOUT
    [ "$1" = mosaic ] || return 0
    local s0; s0=$(state)
    check "$1: opens tiled at its own size" "$([ "$s0" = '362x677 TILED' ] && echo 1)" "$s0"
    $H tap Super+T; sleep 0.8
}
storm() { # FROM TO: the most ConfigureNotify in one second of that span
    python3 -c "
import re,sys
n=[int(m.group(2)) for m in re.finditer(r't=\s*(\d+)s configure=\s*(\d+)', open('$OUT').read()) if $1 <= int(m.group(1)) <= $2]
print(max(n) if n else -1)"; }

for L in dwindle scrolling mosaic; do
    start $L; others 1; insist 10; float_first $L
    $H tap Super+T; sleep 0.8; S1=$(state); sleep 4; $H tap Super+T; sleep 0.8; S2=$(state); sleep 4.5
    check "$L: Super+T tiles it at its own size" "$([ "$S1" = '362x677 TILED' ] && echo 1)" "$S1"
    check "$L: no configure storm while tiled" "$([ "$(storm 3 6)" -le 5 ] && echo 1)" "$(storm 3 6)/s"
    check "$L: Super+T floats it back at its size" "$([ "$S2" = '362x677 FLOAT' ] && echo 1)" "$S2"
done
for L in dwindle mosaic; do
    start $L; others 6; insist 8; float_first $L
    $H tap Super+T; sleep 0.8; S1=$(state); P1=$(where); sleep 6.5
    check "$L, crowded: still its own size (overflows, not squeezed)" "$([ "$S1" = '362x677 TILED' ] && echo 1)" "$S1"
    check "$L, crowded: kept on screen" "$([ "$P1" = on ] && echo 1)" "$P1"
    check "$L, crowded: no configure storm" "$([ "$(storm 3 7)" -le 5 ] && echo 1)" "$(storm 3 7)/s"
done
start mosaic
$H eval 'hl.config({plugin={hyprdrive={mosaic={infinite_canvas=true}}}})' >/dev/null
others 8; insist 9; float_first mosaic # 8: seven windows still fit on the rig's screen
$H tap Super+T; sleep 0.8; S1=$(state); sleep 4.5; C1=$(canvas)
check "infinite canvas: Super+T tiles it at its own size" "$([ "$S1" = '362x677 TILED' ] && echo 1)" "$S1"
check "infinite canvas: no configure storm" "$([ "$(storm 3 6)" -le 5 ] && echo 1)" "$(storm 3 6)/s"
check "infinite canvas: its windows spill past the screen, none on another" "$(set -- $C1; [ "$1" -ge 1 ] && [ "$2" = 0 ] && [ "$3" = 8 ] && echo 1)" "past, overlapping, tiled: $C1"
$H eval 'hl.config({misc={size_limits_tiled=true}, general={gaps_workspaces=0}})' >/dev/null; sleep 1.2; C2=$(canvas)
check "control: misc:size_limits_tiled piles them up (20-layout.lua's mistake)" "$(set -- $C2; [ "$2" -ge 1 ] && echo 1)" "past, overlapping, tiled: $C2"
start mosaic; others 1; insist 10 5; float_first mosaic
$H tap Super+T; sleep 4.5; S1=$(state); sleep 5
check "mosaic: a size change of its own is followed" "$([ "$S1" = '462x727 TILED' ] && echo 1)" "$S1"
check "mosaic: no storm after it changes size" "$([ "$(storm 6 9)" -le 5 ] && echo 1)" "$(storm 6 9)/s"
start dwindle; others 1; insist 8
$H tap Super+T; sleep 1
LOADED=$(sudo -n -u hyprtest test -r "$SO" && echo "$SO" || echo "/tmp/hl-$HL_NAME/staged/$(basename "$SO")")
$H h plugin unload "$LOADED" >/dev/null 2>&1; sleep 0.8; S1=$(state); sleep 5
check "unloaded while tiled: left floating at its size" "$([ "$S1" = '362x677 FLOAT' ] && echo 1)" "$S1"
check "unloaded while tiled: no storm after" "$([ "$(storm 4 7)" -le 5 ] && echo 1)" "$(storm 4 7)/s"

$H stop >/dev/null 2>&1
rm -rf "$SHARE"
echo "own_size_tile gate: $fails failed"
exit "$fails"
