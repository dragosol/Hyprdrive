#!/usr/bin/env bash
# BUG 2 SOAK: "dock previews sometimes don't show, randomly, hard to reproduce".
#
# y11, z1 and x47 all hover ONCE, from a settled desktop, with the overview in
# one known state. A defect that is intermittent is by definition not in the
# state those gates stand in, so this walks the states they do not:
#
#   A  overview CLOSED, plain desktop hover        (y11 and z1 hover with it OPEN)
#   B  overview OPEN                                (the covered path, as control)
#   C  RE-HOVER: leave and come back fast enough to race g_previewed's 250ms TTL
#      against the panel's own re-arm
#   D  hover straight after a MINIMIZE flight, before anything has settled
#
# Every lap is graded the same way and the laps are counted, because "sometimes"
# is a RATE. One blank in forty is a finding; zero in forty over four states is
# also a finding, and a different one.
#
# NON-BLANK is the fixture's magenta ground inside the panel band; LIVE is the
# nanosecond clock it prints across forty rows changing between two frames
# 0.5s apart. A still preview passes any one-frame test, which is why both.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1

TAG=${1:-soak}
OUT=/mnt/host/zrig/fire-phantom2/dock; mkdir -p $OUT; rm -f $OUT/$TAG-*.png
LAPS=${LAPS:-10}
WS_HOME=1
WS_AWAY=7

restore() {
    ov off
    cfg_dock "autohide=true, show_favorites=true, show_apps_button=true, show_trash=true, show_mounts=false"
    dsp "hl.dsp.focus({workspace = $WS_HOME})"
    hyprwall_resume
}
trap restore EXIT
hyprwall_pause

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5
dsp "hl.dsp.focus({workspace = $WS_HOME})"; sleep 0.8
cfg_dock "autohide=false, show_favorites=false, show_apps_button=false, show_trash=false, show_mounts=false"
sleep 0.8

W=2560; H=1600
PARKX=$((W - 60)); PARKY=60

TICKER='while :; do s=$(date +%s%N); printf "\033[H\033[2J"; i=0; while [ $i -lt 40 ]; do printf "%s %d\n" "$s" "$i"; i=$((i+1)); done; sleep 0.08; done'
setsid kitty -c NONE --class DPSOAK --title DPSOAKWIN -o background='#ff00ff' -o foreground='#000000' \
    -o background_opacity=1.0 -o font_size=40 -o confirm_os_window_close=0 --hold sh -c "$TICKER" >/dev/null 2>&1 </dev/null &
sleep 3.5
ADDR=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='DPSOAK'), ''))")
[ -n "$ADDR" ] || { echo "ABORT: DPSOAK did not appear"; exit 1; }

dsp "hl.dsp.window.move({workspace = $WS_AWAY, window = [[address:$ADDR]], follow = false})"; sleep 1.2
for i in 1 2; do
    dsp "hl.dsp.focus({workspace = $WS_AWAY})"; sleep 1.1
    dsp "hl.dsp.focus({workspace = $WS_HOME})"; sleep 1.1
done

# RE-PREDICTED BEFORE EVERY LAP, never cached. A stray toplevel -- the keyring
# prompter is the standing one in this guest -- inserts a dock icon and every
# icon after it MOVES. Measured while building this: a two-lap run went from
# 25400 px of preview to 59 px for the rest of the soak and reported six blanks,
# all of them the rig hovering a cell that had shifted under it. A stale hit
# target reads exactly like the defect being hunted.
strays() {
    hyprctl clients -j | python3 -c "
import json,sys
print(' '.join(sorted({c['class'] for c in json.load(sys.stdin) if c['class'] not in ('DPSOAK',)})))"
}
aim() {
    local s; s=$(strays)
    if [ -n "$s" ]; then
        echo "  stray toplevel(s) appeared: $s -- killing and re-aiming" >&2
        hyprctl clients -j | python3 -c "
import json,sys,os,signal
for c in json.load(sys.stdin):
    if c['class'] != 'DPSOAK' and c.get('pid',0) > 0:
        try: os.kill(c['pid'], signal.SIGKILL)
        except Exception: pass"
        sleep 1.2
    fi
    read -r IX IY <<< "$(hyprctl clients -j | python3 /mnt/host/x47_cell.py DPSOAK)"
    read -r PX PY PW PH <<< "$(hyprctl clients -j | python3 /mnt/host/x47_cell.py panel)"
    [ -n "${IX:-}" ] && [ -n "${PY:-}" ] || { echo "ABORT: could not predict the icon/panel cell"; exit 1; }
    BAND="0,$((PY - 24)) ${W}x$((PH + 24))"
}
aim
echo "icon=$IX,$IY  panel=$PX,$PY ${PW}x${PH}"

grade() { # grade NAME -- two frames 0.5s apart; prints "px_a px_b changed"
    grim -g "$BAND" "$OUT/$TAG-$1-a.png" 2>/dev/null
    sleep 0.5
    grim -g "$BAND" "$OUT/$TAG-$1-b.png" 2>/dev/null
    python3 - "$OUT/$TAG-$1-a.png" "$OUT/$TAG-$1-b.png" <<'PY'
import sys
import numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
b = np.asarray(Image.open(sys.argv[2]).convert("RGB")).astype(int)
def mag(x):
    r, g, bl = x[..., 0], x[..., 1], x[..., 2]
    return int(((r > 110) & (bl > 110) & (g < 90) & (r - g > 60) & (bl - g > 60)).sum())
print(mag(a), mag(b), int((np.abs(a - b).max(axis=2) > 18).sum()))
PY
}

BLANK=0; STILL=0; TOTAL=0
lap() { # lap NAME
    read -r PA PB CH <<< "$(grade "$1")"
    TOTAL=$((TOTAL+1))
    local verdict=ok
    if [ "$PA" -lt 4000 ] || [ "$PB" -lt 4000 ]; then BLANK=$((BLANK+1)); verdict=BLANK; fi
    if [ "$CH" -lt 200 ]; then STILL=$((STILL+1)); verdict="$verdict/STILL"; fi
    printf '  %-18s magenta %6d %6d  changed %6d  %s\n' "$1" "$PA" "$PB" "$CH" "$verdict"
}

echo "=== A: overview CLOSED ==="
ov off; sleep 1.2
for i in $(seq 1 $LAPS); do
    warp $PARKX $PARKY; sleep 0.7
    aim
    warp_or_die $IX $IY; sleep 0.9
    lap "A$i"
done

echo "=== B: overview OPEN (the covered path) ==="
warp $PARKX $PARKY; sleep 0.5
ov on; sleep 2.5
for i in $(seq 1 $LAPS); do
    warp $PARKX $PARKY; sleep 0.7
    aim
    warp_or_die $IX $IY; sleep 0.9
    lap "B$i"
done
ov off; sleep 1.4

echo "=== C: re-hover across the 250ms preview TTL ==="
for i in $(seq 1 $LAPS); do
    aim
    warp_or_die $IX $IY; sleep 0.9
    warp $PARKX $PARKY; sleep 0.30      # inside PREVIEWING_MS
    warp_or_die $IX $IY; sleep 0.35     # back before the panel has finished leaving
    lap "C$i"
done

echo "=== D: hover straight after a minimize/restore flight ==="
for i in $(seq 1 $LAPS); do
    warp $PARKX $PARKY; sleep 0.5
    aim
    dsp "hl.plugin.$RIG_NS.minimize([[address:$ADDR]])" ; sleep 1.0
    warp_or_die $IX $IY; sleep 0.9
    lap "D${i}min"
    warp $PARKX $PARKY; sleep 0.4
    aim
    dsp "hl.plugin.$RIG_NS.minimize([[address:$ADDR]])" ; sleep 1.0
    warp_or_die $IX $IY; sleep 0.9
    lap "D${i}res"
done

warp $PARKX $PARKY; sleep 0.6
echo
echo "laps $TOTAL   blank $BLANK   still $STILL"
[ "$BLANK" = 0 ] && [ "$STILL" = 0 ] && echo "DOCK_SOAK CLEAN" || echo "DOCK_SOAK REPRODUCED"
echo DOCK_SOAK_OK
