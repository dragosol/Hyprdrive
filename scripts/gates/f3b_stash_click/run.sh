#!/usr/bin/env bash
# f3b_stash_click -- clicking a stashed tile ACTS. OVERVIEW_CPP_SPEC 13.14 Y9
# ("a minimized window is still in the overview... so I can see it and filter to
# it"), 13.5 X58(a), and the section 5 checklist that says what a tile click
# does: "focus + raise that window, close overview".
#
# Y9 made a minimized window a legitimate tile and X58(a) made a query reach it.
# Nothing made the CLICK work: close() commits its selection with
# changeWorkspace(closeOnWindow->m_workspace), a stashed window's m_workspace is
# `special:minimized`, and changing to a special workspace does nothing. So the
# overview closed, the desktop did not move, the window stayed stashed -- the one
# tile in the grid that could be seen, filtered to, and not used.
#
# THE SIZE IS THE PROOF, and it carries two clauses at once. Two matching
# windows share the grid, so a TILE is ~740x460 while the window on its desktop
# is 900x560. Measuring the same fixture before and after the press therefore
# says both "it is no longer stashed" and "the overview is not still on top of
# it" -- and neither can be faked by focus alone.
#
#   P1 STASHED   query -> the stashed tile is in the grid at tile size -> click
#                it -> off `special:minimized`, on its home desktop, focused,
#                and drawn at its own full desktop size.
#   P2 CONTROL   the same click, same query, same frame geometry, on the tile
#                that was NEVER minimized. Red P2 means the rig's click did not
#                land and P1's verdict is worth nothing either way.
#
#   P3 CROSS-DESKTOP  the same claim from the OTHER side of the gap this gate
#                  used to declare out of scope. A window stashed from a desktop
#                  that no longer EXISTS -- it was that desktop's last window, so
#                  Hyprland reaped it -- must still come into the grid under a
#                  query and still restore-and-go when clicked. The old
#                  measurement was 0 px against 338550 px for the same window
#                  un-stashed (zrig/f3b/dbg2), and the arm asserts desktop 5 is
#                  really gone before it photographs anything: with the desktop
#                  still alive the case passes on every build and the arm would
#                  be measuring nothing.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=${RIG_EVIDENCE:-/mnt/host/zrig}/f3b_stash; mkdir -p "$OUT"; rm -f "$OUT"/*.png
FAIL=0
bad() { echo "FAIL $*"; FAIL=1; }

gate_slate f3b_stash_click >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }
[ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_pause 30min

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5

headless_on || exit 1
unstash() { dsp "hl.plugin.$RIG_NS.minimize([[restore]])"; }
trap 'ov off; unstash; headless_off; hyprwall_resume' EXIT

dsp "hl.dsp.focus({monitor = \"$RIG_MON\"})"; sleep 0.4

FW=900; FH=560
dsp 'hl.dsp.focus({workspace = 5})'; sleep 0.8
fixture_kitty F3BSTASH 200 400 $FW $FH '#ff00ff' 'clear; sleep infinity' || exit 1
fixture_kitty F3BHOME 1400 400 $FW $FH '#00c000' 'clear; sleep infinity' || exit 1

dsp 'hl.dsp.focus({window = [[class:F3BSTASH]]})'; sleep 0.8
dsp "hl.plugin.$RIG_NS.minimize([[window]])"; sleep 2.5

parked() { hyprctl clients -j | python3 -c "
import json,sys
print(next((c['workspace']['name'] for c in json.load(sys.stdin) if c['class']=='F3BSTASH'), 'ABSENT'))"; }

# Assert the SUBJECT EXISTS before photographing it (y8's three wasted rounds).
# Clicking a window that was never stashed is an ordinary tile click and every
# build passes that.
echo "    F3BSTASH parked on: $(parked)"
[ "$(parked)" = "special:minimized" ] || { echo "FAIL the fixture never got stashed -- rig fault, nothing to test"; exit 1; }

dsp 'hl.dsp.focus({workspace = 5})'; sleep 1.0

locate() { # locate PNG magenta|green [FLOOR] -> "CX CY W H AREA" or nothing
    python3 - "$1" "$2" "${3:-450}" <<'PY'
import sys
sys.path.insert(0, "scripts")
import numpy as np
from PIL import Image
from blob import largest_of
im = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
r, g, b = im[:, :, 0], im[:, :, 1], im[:, :, 2]
if sys.argv[2] == "magenta":
    m = (r > 110) & (b > 110) & (g < 90) & (r - g > 60) & (b - g > 60)
else:
    m = (g > 110) & (r < 90) & (b < 90)
m[:int(sys.argv[3]), :] = False
f = largest_of(m)
if f and f[4] >= 40000:
    print("%d %d %d %d %d" % (f[0] + f[2] // 2, f[1] + f[3] // 2, f[2], f[3], f[4]))
PY
}

state() { # state -> "WSID CLASS"
    hyprctl activeworkspace -j | python3 -c "import json,sys; print(json.load(sys.stdin)['id'], end=' ')"
    hyprctl activewindow -j | python3 -c "import json,sys
d=json.load(sys.stdin); print(d.get('class') or 'none')"
}

echo "--- P1 A STASHED TILE'S CLICK ACTS"
ov on; sleep 2.0
ydotool type 'F3B'; sleep 2.5                      # matches BOTH, so neither is alone in the grid

grim "$OUT/p1-grid.png" 2>/dev/null
read -r PX PY PW PH PAREA <<< "$(locate "$OUT/p1-grid.png" magenta)"
if [ -z "${PAREA:-}" ]; then
    echo "FAIL Y9/X58(a): the query does not reveal the stashed window -- there is no tile to click"
    exit 1
fi
echo "    stashed tile at ${PX},${PY}  ${PW}x${PH}  area ${PAREA}"
python3 -c "import sys; sys.exit(0 if $PW < 830 else 1)" \
    || { echo "FAIL the grid drew the stashed window at ${PW}px, its full desktop width -- tile and window are then the same measurement and P1 cannot conclude anything"; exit 1; }

warp "$PX" "$PY"; sleep 0.5
ydotool click 0x40 >/dev/null 2>&1; sleep 0.12; ydotool click 0x80 >/dev/null 2>&1
sleep 3.0

read -r WS CLS <<< "$(state)"
NOWWS=$(parked)
grim "$OUT/p1-after.png" 2>/dev/null
read -r AX AY AW AH AAREA <<< "$(locate "$OUT/p1-after.png" magenta 0)"
echo "    after the click: workspace $WS, focused $CLS, F3BSTASH on $NOWWS"
echo "    magenta on screen: ${AW:-0}x${AH:-0}  (as a tile it was ${PW}x${PH}, its own size is ${FW}x${FH})"

[ "$NOWWS" = "special:minimized" ] && bad "P1 the click is dead: the window is still stashed"
[ "$WS" = 5 ]           || bad "P1 the overview closed onto desktop $WS, not the window's home desktop 5"
[ "$CLS" = "F3BSTASH" ] || bad "P1 the restored window is not focused (focused $CLS)"
if [ -z "${AAREA:-}" ]; then
    bad "P1 the window is nowhere on screen after the click"
else
    python3 -c "import sys; sys.exit(0 if 850 <= $AW <= 950 and 520 <= $AH <= 600 else 1)" \
        || bad "P1 the window came back at ${AW}x${AH}, not its own ${FW}x${FH} -- still a tile, so the overview did not close onto it"
fi

echo "--- P2 CONTROL: the same click, same query, on the tile that was never stashed"
dsp 'hl.dsp.focus({workspace = 5})'; sleep 1.0
ov on; sleep 2.0
ydotool type 'F3B'; sleep 2.5

grim "$OUT/p2-grid.png" 2>/dev/null
read -r GX GY GW GH GAREA <<< "$(locate "$OUT/p2-grid.png" green)"
[ -n "${GAREA:-}" ] || { echo "FAIL the never-stashed tile is not in the grid -- rig fault"; exit 1; }
echo "    control tile at ${GX},${GY}  ${GW}x${GH}"

warp "$GX" "$GY"; sleep 0.5
ydotool click 0x40 >/dev/null 2>&1; sleep 0.12; ydotool click 0x80 >/dev/null 2>&1
sleep 2.5
read -r WS2 CLS2 <<< "$(state)"
echo "    after the click: workspace $WS2, focused $CLS2"
[ "$CLS2" = "F3BHOME" ] || bad "P2 CONTROL the rig's click does not land at all (focused $CLS2) -- P1 proves nothing"
[ "$WS2" = 5 ]          || bad "P2 CONTROL the click left desktop 5 for $WS2"

echo "--- P3 CROSS-DESKTOP: stashed from a desktop that has since been reaped"
ov off; sleep 1.5

# F3BHOME leaves desktop 5 so the stash below is that desktop's LAST window, and
# lands on 3 so the query still has a second match: a lone match fills the grid
# and the tile stops being smaller than the window, which is what P1's size
# proof rests on.
hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('class')=='F3BHOME' and c.get('pid',0)>0: print(c['pid'])" | xargs -r kill -9 2>/dev/null
sleep 1.5
dsp 'hl.dsp.focus({workspace = 3})'; sleep 0.8
fixture_kitty F3BFAR 1400 400 $FW $FH '#00c000' 'clear; sleep infinity' || exit 1

dsp 'hl.dsp.focus({workspace = 5})'; sleep 0.8
dsp 'hl.dsp.focus({window = [[class:F3BSTASH]]})'; sleep 0.8
dsp "hl.plugin.$RIG_NS.minimize([[window]])"; sleep 2.5
dsp 'hl.dsp.focus({workspace = 3})'; sleep 2.0

wsgone() { hyprctl workspaces -j | python3 -c "
import json,sys
print('gone' if 5 not in [w['id'] for w in json.load(sys.stdin)] else 'alive')"; }

echo "    F3BSTASH parked on: $(parked); desktop 5 is $(wsgone)"
[ "$(parked)" = "special:minimized" ] || { echo "FAIL P3 the fixture never got stashed -- rig fault"; exit 1; }
# THE PRECONDITION. A live desktop 5 still owns a card, the window is listed
# under it, and every build promotes it -- so without this the arm is green on
# the build it is meant to catch.
[ "$(wsgone)" = "gone" ] || { echo "FAIL P3 desktop 5 survived the stash -- this is not the case the arm is for"; exit 1; }

ov on; sleep 2.0
ydotool type 'F3B'; sleep 2.5

grim "$OUT/p3-grid.png" 2>/dev/null
read -r RX RY RW RH RAREA <<< "$(locate "$OUT/p3-grid.png" magenta)"
if [ -z "${RAREA:-}" ]; then
    bad "P3 X58(a): a window stashed from a desktop that no longer exists never joins the grid under a query"
else
    echo "    cross-desktop stashed tile at ${RX},${RY}  ${RW}x${RH}  area ${RAREA}"
    python3 -c "import sys; sys.exit(0 if $RW < 830 else 1)" \
        || bad "P3 the grid drew it at ${RW}px, its full desktop width -- tile and window are then the same measurement"

    warp "$RX" "$RY"; sleep 0.5
    ydotool click 0x40 >/dev/null 2>&1; sleep 0.12; ydotool click 0x80 >/dev/null 2>&1
    sleep 3.0

    read -r WS3 CLS3 <<< "$(state)"
    NOWWS3=$(parked)
    grim "$OUT/p3-after.png" 2>/dev/null
    read -r BX BY BW BH BAREA <<< "$(locate "$OUT/p3-after.png" magenta 0)"
    echo "    after the click: workspace $WS3, focused $CLS3, F3BSTASH on $NOWWS3"
    echo "    magenta on screen: ${BW:-0}x${BH:-0}  (its own size is ${FW}x${FH})"

    [ "$NOWWS3" = "special:minimized" ] && bad "P3 the click is dead: the window is still stashed"
    [ "$WS3" = 5 ]           || bad "P3 the overview closed onto desktop $WS3, not the window's home desktop 5"
    [ "$CLS3" = "F3BSTASH" ] || bad "P3 the restored window is not focused (focused $CLS3)"
    if [ -z "${BAREA:-}" ]; then
        bad "P3 the window is nowhere on screen after the click"
    else
        python3 -c "import sys; sys.exit(0 if 850 <= $BW <= 950 and 520 <= $BH <= 600 else 1)" \
            || bad "P3 the window came back at ${BW}x${BH}, not its own ${FW}x${FH}"
    fi
fi

echo
[ $FAIL = 0 ] && echo "PASS f3b_stash_click" || echo "FAIL f3b_stash_click"
exit $FAIL
