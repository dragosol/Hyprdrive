#!/usr/bin/env bash
# Y12 -- a window stashed FROM the desktop you are looking at owns ONE grid slot.
#
# Y9 put minimized windows back in the overview at the desktop they were
# minimized FROM, and only while a query matches. Two decisions never learned
# that rule and kept reading the window's own m_workspace, which for a stashed
# window is `special:minimized` and can therefore never equal the active
# workspace. So a window minimized FROM the active desktop answered "I live
# somewhere else" and joined the active grid a SECOND time under B2's
# promote-matches-from-every-desktop rule. The layout then solved for N+1: two
# windows laid out as three, which picks two rows, puts both tiles in row 0 and
# leaves row 1 empty. That is the user's "not centered or organized properly".
#
# THE CONTROL IS THE SAME TWO WINDOWS WITH NOTHING STASHED. Both arms have the
# same two fixtures, the same identical geometry, the same query and the same
# card; the only difference is whether one of them is in the stash. Two windows
# are two tiles either way, so the two arms must lay out IDENTICALLY. Predicting
# the grid's own arithmetic instead would just re-implement the bug's neighbour.
#
# The control is captured on BOTH sides of the three stashed laps (doctrine:
# control frames either side of the measured one), and the two controls must
# agree with each other or the run is a rig fault rather than a verdict.
#
# CYCLES, not one shot: three open/query/clear/close laps, every one graded.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1

TAG=${1:-gate}
OUT=/mnt/host/y12; mkdir -p $OUT
rm -f $OUT/$TAG-*.png

# Both fixtures at the SAME size on purpose: the grid scales every tile by one
# common factor, so two different sizes would let a size difference stand in for
# a slot-count difference.
FX=760; FY=560; FW=900; FH=560

# Nowhere near a tile, the strip, the pill or the dock. A hovered tile GROWS,
# and a rig that photographs a grown tile measures its own cursor.
PARKX=2500; PARKY=430

restore() {
    ov off
    dsp "hl.plugin.$RIG_NS.minimize([[restore]])"
    hyprwall_resume
}
trap restore EXIT
hyprwall_pause

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5

# Park the pointer BEFORE the first open. A tile the pointer was resting on when
# the overview opened is mid-HOVER-EASE, and it photographs bigger than its slot
# -- measured on the first run of this gate: ctrlA's green tile came out 768x472
# against 728x456 everywhere else, purely because the previous gate had left the
# cursor over it.
warp $PARKX $PARKY; sleep 0.6

# ws5: a card with neighbours on both sides, so a tile that escapes the card has
# somewhere visible to escape TO.
dsp 'hl.dsp.focus({workspace = 5})'; sleep 0.8
fixture_kitty Y12KEEP $FX $FY $FW $FH '#00c000' 'clear; sleep infinity' || exit 1
fixture_kitty Y12AWAY $FX $FY $FW $FH '#ff00ff' 'clear; sleep infinity' || exit 1
dsp 'hl.dsp.focus({workspace = 5})'; sleep 0.8

geom() { # geom CLASS -> "ws x y w h"
    hyprctl clients -j | python3 -c "
import json,sys
c = next((c for c in json.load(sys.stdin) if c['class']==sys.argv[1]), None)
print('%s %d %d %d %d' % (c['workspace']['id'], c['at'][0], c['at'][1], c['size'][0], c['size'][1]) if c else 'none 0 0 0 0')" "$1"
}

echo "fixtures: KEEP $(geom Y12KEEP) | AWAY $(geom Y12AWAY)"

# Both must really be on ws5 at the size the rig asked for, or "two tiles" is a
# statement about the fixture and not about the grid.
for c in Y12KEEP Y12AWAY; do
    read -r ws x y w h <<< "$(geom $c)"
    [ "$ws" = 5 ] || { echo "ABORT: $c is on ws$ws, not ws5"; exit 1; }
    [ "$w" -gt $((FW-9)) ] && [ "$w" -lt $((FW+9)) ] && [ "$h" -gt $((FH-9)) ] && [ "$h" -lt $((FH+9)) ] \
        || { echo "ABORT: $c is ${w}x${h}, the rig placed it ${FW}x${FH}"; exit 1; }
done

shoot() { # shoot NAME -- open, query, park, capture, clear, close
    ov on; sleep 1.8
    ydotool type 'Y12' >/dev/null 2>&1
    sleep 2.2
    warp $PARKX $PARKY; sleep 1.4
    grim "$OUT/$TAG-$1.png"
    for _ in 1 2 3; do ydotool key 14:1 14:0 >/dev/null 2>&1; sleep 0.12; done
    sleep 0.8
    ov off; sleep 1.6
    echo "  captured $1"
}

echo "=== control A: nothing stashed ==="
shoot ctrlA

echo "=== stash Y12AWAY from ws5 ==="
dsp 'hl.dsp.focus({window = [[class:Y12AWAY]]})'; sleep 0.6
dsp "hl.plugin.$RIG_NS.minimize([[window]])"; sleep 1.8
dsp 'hl.dsp.focus({workspace = 5})'; sleep 1.0
read -r ws x y w h <<< "$(geom Y12AWAY)"
[ "$ws" = 5 ] && { echo "ABORT: the minimize did not stash Y12AWAY (still ws5)"; exit 1; }
echo "stashed: Y12AWAY ws$ws ${w}x${h}"
# The stash must not have RESIZED it, or the two arms are not comparable.
[ "$w" -gt $((FW-9)) ] && [ "$w" -lt $((FW+9)) ] && [ "$h" -gt $((FH-9)) ] && [ "$h" -lt $((FH+9)) ] \
    || { echo "ABORT: stashing resized Y12AWAY to ${w}x${h}"; exit 1; }

for lap in 1 2 3; do
    echo "=== stashed lap $lap ==="
    shoot lap$lap
done

echo "=== restore, control B: nothing stashed again ==="
dsp "hl.plugin.$RIG_NS.minimize([[restore]])"; sleep 1.8
dsp 'hl.dsp.focus({workspace = 5})'; sleep 1.0
read -r ws x y w h <<< "$(geom Y12AWAY)"
[ "$ws" = 5 ] || { echo "ABORT: the restore did not bring Y12AWAY back to ws5 (ws$ws)"; exit 1; }
shoot ctrlB

echo "frames: $(ls $OUT/$TAG-*.png | wc -l)"
echo Y12_RIG_OK
