#!/usr/bin/env bash
# Z3 driver. Runs ON THE HOST because the fixture has to be LOCATED between
# gestures -- the strip minis move as windows change desktop, and the standing
# rule is that a rig never reuses an old hit target.
#
# Three gestures on one window, in one overview session:
#
#   G1  main tile -> another desktop's strip mini
#       That desktop's card is off-screen, so this is the case that always
#       worked. Position must be kept.
#
#   G2  strip mini -> the strip mini of the desktop whose card FILLS THE VIEW
#       The bug. X42 assumed a strip drop always targets an off-screen card, so
#       this took the "map the cursor into the card" branch with a cursor that
#       was up in the strip band. Measured on the broken build: (200,150) ->
#       (324,1), i.e. jammed against the top edge. Position must be kept.
#
#   G3  strip mini -> INSIDE the main card                        [CONTROL]
#       A genuine in-card drop, which must still land where it was dropped.
#       Without this, a fix that simply stopped mapping the cursor anywhere
#       would pass G1 and G2 and have broken drag-to-place entirely.
#
# usage: z3_run.sh
set -u
cd "$(dirname "$0")/.."
G=./g
SHARE=./share
HOME_AT="[200, 150]"

blobs() {   # <png> <band|full>  -> "colour cx cy" lines
    python3 - "$1" "$2" <<'EOF'
import sys
import numpy as np
from PIL import Image
png, mode = sys.argv[1], sys.argv[2]
a = np.asarray(Image.open(png).convert('RGB')).astype(int)
Y0, Y1 = (240, 400) if mode == 'band' else (0, a.shape[0])
sub = a[Y0:Y1]
r, g, b = sub[:, :, 0], sub[:, :, 1], sub[:, :, 2]
S = 2
def blobs(mask, minpx=20):
    small = mask[::S, ::S]
    seen = np.zeros_like(small); out = []
    for sy, sx in zip(*np.where(small)):
        if seen[sy, sx]:
            continue
        st = [(sy, sx)]; comp = []; seen[sy, sx] = True
        while st:
            y, x = st.pop(); comp.append((y, x))
            for ny, nx in ((y-1, x), (y+1, x), (y, x-1), (y, x+1)):
                if 0 <= ny < small.shape[0] and 0 <= nx < small.shape[1] and small[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True; st.append((ny, nx))
        if len(comp) >= minpx:
            ys = [c[0] for c in comp]; xs = [c[1] for c in comp]
            out.append((len(comp), (min(xs)*S + max(xs)*S)//2, (min(ys)*S + max(ys)*S)//2 + Y0))
    return sorted(out, reverse=True)
for name, m in (('red', (r > 120) & (g < 90) & (b < 90)),
                ('yellow', (r > 120) & (g > 120) & (b < 100)),
                ('cyan', (g > 120) & (b > 120) & (r < 100))):
    hit = blobs(m)
    print(name, hit[0][1], hit[0][2]) if hit else print(name, 'NONE', 'NONE')
EOF
}

at() { $G 'hyprctl clients -j' | python3 -c "
import json,sys
print(next((str(c['at']) for c in json.load(sys.stdin) if c['class']=='MARK'), '?'))"; }
ws() { $G 'hyprctl clients -j' | python3 -c "
import json,sys
print(next((str(c['workspace']['id']) for c in json.load(sys.stdin) if c['class']=='MARK'), '?'))"; }

echo "=== setup ==="
$G 'bash /mnt/host/z3_setup.sh 2>&1 | tail -2'

# G1 -----------------------------------------------------------------------
eval "$(blobs $SHARE/z3/view-ws1.png full | awk '{print $1"_x="$2"; "$1"_y="$3}')"
# No strip means no overview, and the usual cause is that the PLUGIN IS NOT
# LOADED -- which reads as "the fixture is wrong" for a good ten minutes if the
# rig does not say so. `hyprctl plugin list` and the config error overlay both
# name it; `No fns for hook renderWorkspace` after a run of share/hyprrestart.sh
# means the SESSION is spent, not the code: reboot with share/x4bd_cycle.sh.
if [ "$yellow_x" = NONE ] || [ "$cyan_x" = NONE ]; then
    echo "ABORT: no desktop strip in the capture -- is the plugin loaded?"
    $G 'hyprctl plugin list' | head -3
    exit 2
fi
echo "=== G1: main tile ($red_x,$red_y) -> ws2 strip mini ($yellow_x,$yellow_y) ==="
$G "bash /mnt/host/z3_drag.sh $red_x $red_y $yellow_x $yellow_y g1 2>&1 | tail -2"
G1_AT=$(at); G1_WS=$(ws)
echo "after G1: ws=$G1_WS at=$G1_AT"

# G2 -----------------------------------------------------------------------
# The destination is the mini of the desktop the viewport is SHOWING, which is
# the one whose card is fully visible. Its slot is one pitch left of ws2's,
# taken from the two minis actually found rather than from a remembered number.
$G 'bash /mnt/host/z3_shot.sh g1shot' >/dev/null
eval "$(blobs $SHARE/z3/g1shot.png band | awk '{print $1"_x="$2"; "$1"_y="$3}')"
PITCH=$(( cyan_x - yellow_x ))
WS1_X=$(( yellow_x - PITCH )); WS1_Y=$cyan_y
echo "=== G2: MARK mini ($red_x,$red_y) -> ws1 strip mini ($WS1_X,$WS1_Y), pitch $PITCH ==="
$G "bash /mnt/host/z3_drag.sh $red_x $red_y $WS1_X $WS1_Y g2 2>&1 | tail -2"
G2_AT=$(at); G2_WS=$(ws)
echo "after G2: ws=$G2_WS at=$G2_AT"

# G3 (control) -------------------------------------------------------------
# Park MARK back on ws2 so there is a workspace to move FROM, then drop it deep
# inside the main card.
$G 'bash /mnt/host/z3_shot.sh g2shot' >/dev/null
eval "$(blobs $SHARE/z3/g2shot.png band | awk '{print $1"_x="$2"; "$1"_y="$3}')"
$G "bash /mnt/host/z3_drag.sh $red_x $red_y $yellow_x $yellow_y g3a 2>&1 | tail -1" >/dev/null
$G 'bash /mnt/host/z3_shot.sh g3shot' >/dev/null
eval "$(blobs $SHARE/z3/g3shot.png band | awk '{print $1"_x="$2"; "$1"_y="$3}')"
echo "=== G3 control: MARK mini ($red_x,$red_y) -> inside the main card (700,1150) ==="
$G "bash /mnt/host/z3_drag.sh $red_x $red_y 700 1150 g3 2>&1 | tail -2"
G3_AT=$(at); G3_WS=$(ws)
echo "after G3: ws=$G3_WS at=$G3_AT"

echo
FAILED=0
[ "$G1_AT" = "$HOME_AT" ] || { echo "G1 FAIL: position lost on the first move ($G1_AT)"; FAILED=1; }
[ "$G2_AT" = "$HOME_AT" ] || { echo "G2 FAIL: position lost dropping on the VISIBLE card's mini ($G2_AT)"; FAILED=1; }
[ "$G3_AT" = "$HOME_AT" ] && { echo "G3 CONTROL BROKEN: an in-card drop no longer places the window"; FAILED=1; }

[ $FAILED = 0 ] && echo "Z3 PASS -- a strip drop keeps the window's coordinates, an in-card drop still places it" \
                || echo "Z3 FAIL"
exit $FAILED
