#!/usr/bin/env bash
# parity.sh -- the same scripted scenes on Hyprland 0.56 and 0.57, pixel-diffed.
#
# Runs one headless rig instance per side (tests/rig/headless/hl.sh), one after
# the other so they never compete for the GPU:
#   0.56: the system Hyprland + P56_SO (default: the hyprland-native checkout's
#         hyprdrive.so), HL_NAME=gpar56
#   0.57: HL_PREFIX=P57_PREFIX (default /tmp/hl057) + P57_SO (default: this
#         tree's hyprdrive.so), HL_NAME=gpar57
# Each scene is screenshotted on both, and per scene this prints the number of
# pixels that differ by more than PAR_TOL (default 2) on any channel, and the
# bounding box of the largest 8-connected blob of them (after a 1 px dilation,
# so an antialiased edge is one blob, not a dotted line).
#
# Usage: tests/rig/parity.sh [OUTDIR]      (default /tmp/hdpar; made chmod 777)
#        PAR_ONLY=56|57  run one side only (the other's shots must already be in OUTDIR)
#        PAR_COMPARE=1   only compare the shots already in OUTDIR
#        PAR_STRIP_X/Y   the hover_strip point (default 960,215: desktop 2's strip
#                        cell on the rig's 1920x1080 default overview)
#        P56_SO / P57_SO / P57_PREFIX   the builds and the 0.57 install (see above)
# Noise floor (0.56 against itself, 2026-11-16): 4 px in hover_dock/dock_menu,
# the dock plate's corner antialiasing at 543,1073 and 1371,1074, +-3.
# Shots: OUTDIR/<side>/<scene>.png, the diff mask OUTDIR/diff/<scene>.png.
#
# Determinism: fixed classes and sizes (kitty, cursor_blink_interval=0), the
# pointer parked in the same place before every scene, a settle before every
# shot, and the scenes always in the same order on a fresh instance.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
R=$ROOT/tests/rig/headless/hl.sh
OUT=${1:-/tmp/hdpar}
P56_SO=${P56_SO:-/home/dragos/Projects/hyprdrive-native/hyprdrive.so}
P57_SO=${P57_SO:-$ROOT/hyprdrive.so}
P57_PREFIX=${P57_PREFIX:-/tmp/hl057}
TOL=${PAR_TOL:-2}
SETTLE=${PAR_SETTLE:-1.5}
SCENES="desktop overview search hover_tile hover_strip hover_dock dock_menu desktop2"

mkdir -p "$OUT/56" "$OUT/57" "$OUT/diff"; chmod 777 "$OUT" "$OUT/56" "$OUT/57" "$OUT/diff"
SU() { sudo -n -u hyprtest "$@"; }

# run_side 56|57 -- one fresh instance, every scene, then stop
run_side() {
    local side=$1 so prefix
    if [ "$side" = 56 ]; then export HL_NAME=gpar56; unset HL_PREFIX; so=$P56_SO
    else export HL_NAME=gpar57; export HL_PREFIX=$P57_PREFIX; so=$P57_SO; fi
    local ST=/tmp/hl-$HL_NAME RT=/tmp/hl-$HL_NAME/rt SIG
    $R stop >/dev/null 2>&1 || true
    $R start --so "$so" > "$OUT/$side/start.log" 2>&1 || { echo "parity: $side did not start"; tail -5 "$OUT/$side/start.log"; return 1; }
    trap '$R stop >/dev/null 2>&1' RETURN
    SIG=$(SU cat "$ST/sig")
    hq() { SU env XDG_RUNTIME_DIR="$RT" HYPRLAND_INSTANCE_SIGNATURE="$SIG" PATH=${HL_PREFIX:+$HL_PREFIX/bin:}/usr/bin LD_LIBRARY_PATH=${HL_PREFIX:+$HL_PREFIX/lib64} hyprctl "$@"; }
    ev() { hq eval "$*" >/dev/null; }
    dbg() { hq dispatch "hl.plugin.hyprdrive.debug(\"$*\")" 2>&1; }
    go() { ev "hl.dispatch(hl.dsp.focus({ workspace = \"$1\" }))"; }
    kw() {
        $R win kitty -o cursor_blink_interval=0 -o remember_window_size=no -o initial_window_width="$2" -o initial_window_height="$3" --class "$1" >/dev/null
        local i; for i in $(seq 50); do hq -j clients | jq -e ".[] | select(.class == \"$1\")" >/dev/null 2>&1 && return; sleep 0.1; done
        echo "parity: $side: $1 never mapped"
    }
    park() { $R ptr move 960 540 >/dev/null; }
    shot() { sleep "$SETTLE"; $R shot "$OUT/$side/$1.png" >/dev/null || echo "parity: $side: no shot $1"; }
    centre() { set -- $(echo "$*" | tr ',x' '  '); echo "$(( $1 + $3 / 2 )) $(( $2 + $4 / 2 ))"; }
    sleep 2                                   # the load's desktop compaction (lib.sh rig_start)
    ev 'hl.config({plugin={hyprdrive={dock={autohide=false}}}})'
    go 1; kw pa 900 600; kw pb 700 450
    go 2; kw pc 800 500
    go 1; sleep 1.5

    park; shot desktop
    $R overview >/dev/null; sleep 1; shot overview
    $R type parity >/dev/null; shot search
    $R tap Escape >/dev/null; sleep 0.3
    # Escape may clear the query or close the overview; make sure it is open, query-less
    if ! dbg "tile pa" | grep -q '^tile\|tile pa'; then $R overview >/dev/null; sleep 1; fi
    local T; T=$(dbg "tile pa" | grep -o 'tile pa [-0-9 ]*' | awk '{print $3","$4" "$5"x"$6}')
    if [ -n "$T" ]; then $R ptr move $(centre "$T") >/dev/null; shot hover_tile
    else echo "parity: $side: no tile for pa ($(dbg "tile pa"))"; fi
    $R ptr move "${PAR_STRIP_X:-960}" "${PAR_STRIP_Y:-215}" >/dev/null; shot hover_strip
    $R overview >/dev/null; sleep 1; park; sleep 0.5
    local ICON; ICON=$(dbg dockmenu | grep -o 'icon [a-z]* [-0-9]*,[-0-9]* [0-9]*x[0-9]*' | head -1 | awk '{print $3, $4}')
    if [ -n "$ICON" ]; then
        $R ptr move $(centre $ICON) >/dev/null; shot hover_dock
        $R ptr click right >/dev/null; shot dock_menu
        $R ptr move 700 300 >/dev/null; sleep 0.3; $R ptr click left >/dev/null; sleep 0.8
    else echo "parity: $side: no dock icon ($(dbg dockmenu | head -3 | tr '\n' ' '))"; fi
    go 2; park; shot desktop2
}

case ${PAR_COMPARE:-0} in
    1) ;;
    *) [ "${PAR_ONLY:-}" = 57 ] || run_side 56
       [ "${PAR_ONLY:-}" = 56 ] || run_side 57 ;;
esac

python3 -P - "$OUT" "$TOL" $SCENES <<'PY'
import sys, os
import numpy as np
from PIL import Image
out, tol, scenes = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
try:
    from scipy import ndimage
except ImportError:
    ndimage = None

def blobs(mask):
    if ndimage is not None:
        lab, n = ndimage.label(mask, structure=np.ones((3, 3)))
        if n == 0:
            return None
        sizes = ndimage.sum(mask, lab, range(1, n + 1))
        k = int(np.argmax(sizes)) + 1
        ys, xs = np.nonzero(lab == k)
        return int(sizes[k - 1]), (xs.min(), ys.min(), xs.max() - xs.min() + 1, ys.max() - ys.min() + 1)
    # fallback: flood fill on a downscaled grid would lie; do a plain BFS
    h, w = mask.shape
    seen = np.zeros_like(mask, bool); best = None
    for y0, x0 in zip(*np.nonzero(mask)):
        if seen[y0, x0]:
            continue
        st = [(y0, x0)]; seen[y0, x0] = True; pts = []
        while st:
            y, x = st.pop(); pts.append((y, x))
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < h and 0 <= xx < w and mask[yy, xx] and not seen[yy, xx]:
                        seen[yy, xx] = True; st.append((yy, xx))
        if best is None or len(pts) > best[0]:
            ys = [p[0] for p in pts]; xs = [p[1] for p in pts]
            best = (len(pts), (min(xs), min(ys), max(xs) - min(xs) + 1, max(ys) - min(ys) + 1))
    return best

print(f"{'scene':<12} {'differing px':>12}  largest blob (x,y wxh, px)")
for s in scenes:
    a_p, b_p = f"{out}/56/{s}.png", f"{out}/57/{s}.png"
    if not (os.path.exists(a_p) and os.path.exists(b_p)):
        print(f"{s:<12} {'MISSING':>12}  56:{os.path.exists(a_p)} 57:{os.path.exists(b_p)}")
        continue
    a = np.asarray(Image.open(a_p).convert("RGB")).astype(int)
    b = np.asarray(Image.open(b_p).convert("RGB")).astype(int)
    if a.shape != b.shape:
        print(f"{s:<12} {'SIZE':>12}  {a.shape} vs {b.shape}")
        continue
    m = np.abs(a - b).max(axis=2) > tol
    n = int(m.sum())
    Image.fromarray((m * 255).astype(np.uint8)).save(f"{out}/diff/{s}.png")
    if n == 0:
        print(f"{s:<12} {0:>12}  -")
        continue
    d = m.copy()
    d[1:, :] |= m[:-1, :]; d[:-1, :] |= m[1:, :]; d[:, 1:] |= m[:, :-1]; d[:, :-1] |= m[:, 1:]
    sz, (x, y, w, h) = blobs(d)
    print(f"{s:<12} {n:>12}  {x},{y} {w}x{h} ({sz} px)")
PY
