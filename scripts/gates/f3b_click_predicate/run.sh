#!/usr/bin/env bash
# f3b_click_predicate -- the tile the render paints is the tile the hit-test
# hands back. OVERVIEW_CPP_SPEC section 5 checklist ("Click / activate tile:
# focus + raise that window, close overview") and 13.5 X16.
#
# The divergence this closes: the render admitted a window through
# `PROMOTED || shouldShowOverviewWindow`, windowAtOverviewPoint asked the gate
# ALONE. A promoted or releasing tile was therefore drawn and unclickable -- the
# press fell through it to the workspace CARD underneath, which is the residual
# half of the user's "the click took me to an empty desktop".
#
# WHY IT IS GATEABLE NOW. It was not before: the outbound tile was on screen for
# one or two frames, and no honest click can be aimed inside that. With the
# release on the house accel curve the tile is nearly stationary for the first
# half of its exit, so the rig can photograph it, aim at the blob it just
# photographed, PROVE the tile is still under the pointer, and only then press.
#
# TWO ARMS, and the control is not decoration:
#   P1 RELEASING   click the centre of a tile that has stopped matching and is
#                  mid-exit -> that window is focused and its OWN desktop is
#                  active. On a build with the split predicate the press misses
#                  the tile entirely and the overview closes back onto the
#                  desktop it started on.
#   P2 CONTROL     the same click, same session, on the SURVIVING tile -> that
#                  window is focused. If P2 is red the rig's click never landed
#                  and P1's verdict means nothing either way.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=${RIG_EVIDENCE:-/mnt/host/zrig}/f3b_click; mkdir -p "$OUT"; rm -f "$OUT"/*.png
FAIL=0
bad() { echo "FAIL $*"; FAIL=1; }

gate_slate f3b_click_predicate >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }
[ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_pause 30min

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5

headless_on || exit 1
trap 'ov off; anim_restore; headless_off; hyprwall_resume' EXIT

dsp "hl.dsp.focus({monitor = \"$RIG_MON\"})"; sleep 0.4

FX=760; FY=560; FW=900; FH=560
# AWAY lives on desktop 5, HOME on desktop 3 and 3 is where we are standing. So
# "the away window's own desktop" and "the desktop the overview opened on" are
# different numbers, and the verdict can tell them apart.
dsp 'hl.dsp.focus({workspace = 5})'; sleep 0.6
fixture_kitty F3BAWAY $FX $FY $FW $FH '#ff00ff' 'clear; sleep infinity' || exit 1
dsp 'hl.dsp.focus({workspace = 3})'; sleep 0.6
fixture_kitty F3BHOME $FX $FY $FW $FH '#00c000' 'clear; sleep infinity' || exit 1
dsp 'hl.dsp.focus({workspace = 3})'; sleep 1.0

# Locate a fixture's tile by colour, as the LARGEST CONNECTED BLOB below the
# strip band -- the strip draws a mini of the same window, and a bounding box
# over both lands the click in the gap between them.
locate() { # locate PNG magenta|green  -> "CX CY AREA" or nothing
    python3 - "$1" "$2" <<'PY'
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
m[:450, :] = False
f = largest_of(m)
if f and f[4] >= 40000:
    print("%d %d %d" % (f[0] + f[2] // 2, f[1] + f[3] // 2, f[4]))
PY
}

state() { # state -> "WSID CLASS"
    hyprctl activeworkspace -j | python3 -c "import json,sys; print(json.load(sys.stdin)['id'], end=' ')"
    hyprctl activewindow -j | python3 -c "import json,sys
d=json.load(sys.stdin); print(d.get('class') or 'none')"
}

# anim_scale 20: the release is 225ms, and the accel curve spends the first half
# of that going almost nowhere, so there is a wide, honest window to aim in.
anim_slow 20 || exit 1

echo "--- P1 RELEASING TILE TAKES THE PRESS"
ov on; sleep 3.0
ydotool type 'F3B'; sleep 6.0

grim "$OUT/p1-promoted.png" 2>/dev/null
read -r PX PY PAREA <<< "$(locate "$OUT/p1-promoted.png" magenta)"
[ -n "${PAREA:-}" ] || { echo "FAIL the away tile never joined the grid -- rig fault, nothing to click"; exit 1; }
echo "    promoted away tile centre ${PX},${PY}  area ${PAREA}"

ydotool type 'HOME'                       # F3BAWAY stops matching -> release
sleep 0.8
warp "$PX" "$PY"; sleep 0.5

# PROVE the tile is still under the pointer at press time. Without this the arm
# cannot tell "the click was ignored" from "the click arrived after the tile had
# gone", and those are different bugs with the same verdict.
grim "$OUT/p1-atpress.png" 2>/dev/null
read -r QX QY QAREA <<< "$(locate "$OUT/p1-atpress.png" magenta)"
if [ -z "${QAREA:-}" ]; then
    echo "FAIL the releasing tile was already gone when the rig pressed -- widen anim_scale"
    exit 1
fi
echo "    at press: tile centre ${QX},${QY}  area ${QAREA}  (pointer at ${PX},${PY})"
python3 -c "import sys; sys.exit(0 if abs($QX-$PX) < 370 and abs($QY-$PY) < 230 else 1)" \
    || { echo "FAIL the tile had travelled off the pointer before the press (${QX},${QY} vs ${PX},${PY})"; exit 1; }

ydotool click 0x40 >/dev/null 2>&1; sleep 0.12; ydotool click 0x80 >/dev/null 2>&1
sleep 3.5
read -r WS CLS <<< "$(state)"
echo "    after the click: workspace $WS, focused $CLS"
[ "$CLS" = "F3BAWAY" ] || bad "P1 the press on the releasing tile did not focus it (focused $CLS)"
[ "$WS" = 5 ]          || bad "P1 the overview closed onto desktop $WS, not the away window's own desktop 5"

echo "--- P2 CONTROL: the same click on the surviving tile"
ov off; sleep 1.5
dsp 'hl.dsp.focus({workspace = 3})'; sleep 0.8
ov on; sleep 3.0
ydotool type 'F3B'; sleep 6.0

grim "$OUT/p2-grid.png" 2>/dev/null
read -r GX GY GAREA <<< "$(locate "$OUT/p2-grid.png" green)"
[ -n "${GAREA:-}" ] || { echo "FAIL the home tile is not in the grid -- rig fault"; exit 1; }
echo "    home tile centre ${GX},${GY}  area ${GAREA}"

warp "$GX" "$GY"; sleep 0.5
ydotool click 0x40 >/dev/null 2>&1; sleep 0.12; ydotool click 0x80 >/dev/null 2>&1
sleep 3.0
read -r WS2 CLS2 <<< "$(state)"
echo "    after the click: workspace $WS2, focused $CLS2"
[ "$CLS2" = "F3BHOME" ] || bad "P2 CONTROL the rig's click does not land at all (focused $CLS2) -- P1 proves nothing"
[ "$WS2" = 3 ]          || bad "P2 CONTROL the click left desktop 3 for $WS2"

anim_restore
echo
[ $FAIL = 0 ] && echo "PASS f3b_click_predicate" || echo "FAIL f3b_click_predicate"
exit $FAIL
