#!/usr/bin/env bash
# z3_position_memory -- guest-side orchestrator, ported from the host driver
# scripts/z3_run.sh (which drove the guest through ~/hyprvm/g). We ARE the
# guest here, so every `$G '...'` became the command itself; the locator, the
# gesture order and the verdict are the driver's, byte-for-byte.
#
# Three gestures on one window, in one overview session:
#   G1  main tile -> another desktop's strip mini      (always worked, keep)
#   G2  strip mini -> mini of the desktop FILLING the view  (the X42 bug:
#       (200,150) -> (324,1))
#   G3  strip mini -> INSIDE the main card             [CONTROL: a fix that
#       stopped mapping entirely would break drag-to-place]
# MARK parked at 200,150 so a lost coordinate cannot land there by accident;
# every hit target is relocated between gestures (never reuse an old one);
# z3_shot photographs WITHOUT reopening (reopen destroys drag state).
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

SHARE=/mnt/host
HOME_AT="[200, 150]"

# z3_setup.sh builds its headless output WITHOUT headless_on (it must outlive
# that script), so this wrapper owns the teardown: force the flag so
# headless_off actually runs, wallpaper timer back, overview closed.
cleanup() { ov off; RIG_HEADLESS=1; headless_off; hyprwall_resume; }
trap cleanup EXIT

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

at() { hyprctl clients -j | python3 -c "
import json,sys
print(next((str(c['at']) for c in json.load(sys.stdin) if c['class']=='MARK'), '?'))"; }
ws() { hyprctl clients -j | python3 -c "
import json,sys
print(next((str(c['workspace']['id']) for c in json.load(sys.stdin) if c['class']=='MARK'), '?'))"; }

echo "=== setup ==="
bash scripts/z3_setup.sh 2>&1 | tail -2
alive_or_die "after z3 setup"

# G1 -----------------------------------------------------------------------
# The TILE comes from the whole frame (it is in the main card, below the band);
# the two STRIP MINIS come from the band, exactly as G2 and G3 already take
# them. G1 used to take all three from the whole frame, and its yellow mask is
# broad: on wp03 (dry golden hillsides, 5.3% of its pixels inside that mask)
# the largest yellow blob was the WALLPAPER -- 2871 px at (1925,1217) -- while
# the mini it wanted was third-largest at 570 px. G1 then dragged the window
# into the main card and the gate reported "position lost". Deterministic, and
# not a build difference: identical numbers on HEAD and on a4189e2
# (zrig/phase8/Z3_FINDING.md). Eleven of the twenty-two wallpapers score 0.0%
# on that mask, which is the only reason this has been green.
eval "$(blobs $SHARE/z3/view-ws1.png full | awk '$1 == "red" {print "red_x="$2"; red_y="$3}')"
eval "$(blobs $SHARE/z3/view-ws1.png band | awk '$1 != "red" {print $1"_x="$2"; "$1"_y="$3}')"
# No strip means no overview, and the usual cause is that the PLUGIN IS NOT
# LOADED -- which reads as "the fixture is wrong" for a good ten minutes if the
# rig does not say so. `hyprctl plugin list` and the config error overlay both
# name it; `No fns for hook renderWorkspace` after a run of share/hyprrestart.sh
# means the SESSION is spent, not the code: reboot with share/x4bd_cycle.sh.
if [ "$yellow_x" = NONE ] || [ "$cyan_x" = NONE ]; then
    echo "ABORT: no desktop strip in the capture -- is the plugin loaded?"
    hyprctl plugin list | head -3
    exit 2
fi
echo "=== G1: main tile ($red_x,$red_y) -> ws2 strip mini ($yellow_x,$yellow_y) ==="
bash scripts/z3_drag.sh $red_x $red_y $yellow_x $yellow_y g1 2>&1 | tail -2
G1_AT=$(at); G1_WS=$(ws)
echo "after G1: ws=$G1_WS at=$G1_AT"

# G2 -----------------------------------------------------------------------
# The destination is the mini of the desktop the viewport is SHOWING, which is
# the one whose card is fully visible. Its slot is one pitch left of ws2's,
# taken from the two minis actually found rather than from a remembered number.
bash scripts/z3_shot.sh g1shot >/dev/null
eval "$(blobs $SHARE/z3/g1shot.png band | awk '{print $1"_x="$2"; "$1"_y="$3}')"
PITCH=$(( cyan_x - yellow_x ))
WS1_X=$(( yellow_x - PITCH )); WS1_Y=$cyan_y
echo "=== G2: MARK mini ($red_x,$red_y) -> ws1 strip mini ($WS1_X,$WS1_Y), pitch $PITCH ==="
bash scripts/z3_drag.sh $red_x $red_y $WS1_X $WS1_Y g2 2>&1 | tail -2
G2_AT=$(at); G2_WS=$(ws)
echo "after G2: ws=$G2_WS at=$G2_AT"

# G3 (control) -------------------------------------------------------------
# Park MARK back on ws2 so there is a workspace to move FROM, then drop it deep
# inside the main card.
bash scripts/z3_shot.sh g2shot >/dev/null
eval "$(blobs $SHARE/z3/g2shot.png band | awk '{print $1"_x="$2"; "$1"_y="$3}')"
bash scripts/z3_drag.sh $red_x $red_y $yellow_x $yellow_y g3a 2>&1 | tail -1 >/dev/null
bash scripts/z3_shot.sh g3shot >/dev/null
eval "$(blobs $SHARE/z3/g3shot.png band | awk '{print $1"_x="$2"; "$1"_y="$3}')"
echo "=== G3 control: MARK mini ($red_x,$red_y) -> inside the main card (700,1150) ==="
bash scripts/z3_drag.sh $red_x $red_y 700 1150 g3 2>&1 | tail -2
G3_AT=$(at); G3_WS=$(ws)
echo "after G3: ws=$G3_WS at=$G3_AT"
alive_or_die "after the z3 gestures"

echo
FAILED=0
[ "$G1_AT" = "$HOME_AT" ] || { echo "G1 FAIL: position lost on the first move ($G1_AT)"; FAILED=1; }
[ "$G2_AT" = "$HOME_AT" ] || { echo "G2 FAIL: position lost dropping on the VISIBLE card's mini ($G2_AT)"; FAILED=1; }
[ "$G3_AT" = "$HOME_AT" ] && { echo "G3 CONTROL BROKEN: an in-card drop no longer places the window"; FAILED=1; }

[ $FAILED = 0 ] && echo "Z3 PASS -- a strip drop keeps the window's coordinates, an in-card drop still places it" \
                || echo "Z3 FAIL"
exit $FAILED
