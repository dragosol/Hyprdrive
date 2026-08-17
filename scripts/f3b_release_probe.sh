#!/usr/bin/env bash
# F3-b OUTBOUND PROBE, and a standing ticket.
#
# OVERVIEW_CPP_SPEC 13.2 F3-b says a promoted tile that stops matching is
# "released back OUT to its own desktop", and GridLayout.cpp implements that
# carefully -- an armed entry, a clock anchored to the first frame the match is
# seen gone, a 50ms grace so the ease outlives the reflow.
#
# IT DOES NOT PLAY. Measured 2026-08-17 on 9201a96 and again with the phantom
# fix in, at anim_scale 20 -- so 350ms of release is SEVEN SECONDS of wall clock
# -- sampling fourteen frames across two seconds after the match dies:
#
#     t000  magenta 342953 px      still matching, promoted, settled
#     t001  magenta  14310 px      releasing: one frame, and already fading
#     t002+ magenta      0 px      gone, with ~6.8s of release left to run
#
# So the outbound animation is cut after a single frame. The render list is NOT
# the cause: admitting promoted windows to addOverviewWindow was tried, and t001
# went 14310 -> 48595 px with t002 still zero. It is not expiry either (the
# clock has 6.8s left), nor validMapped, nor a rebuild -- onPreRender rebuilds
# only on the empty<->non-empty EDGE of the query, and this transition is
# non-empty to non-empty.
#
# It matters beyond the missing animation. The hit-test admits a tile only
# through the membership gate, while the render admits it through the gate OR
# the promotion, so for as long as a releasing tile IS drawn it cannot be
# clicked and the press falls through to the CARD underneath -- which switches
# desktop. That divergence is real and measured (48 RENDER-UNCLICK lines in one
# soak, some of them hit=none), but at one frame wide no honest gate can be
# built on it. Fix the release first; then unify the two predicates and gate
# both together.
set -u
source "$HOME/overview-cpp/scripts/lib/rig.sh"
rig_env || exit 1

OUT=/mnt/host/zrig/fire-phantom2/probe3; mkdir -p $OUT; rm -f $OUT/*.png
FX=760; FY=560; FW=900; FH=560
SLOW=${SLOW:-20}

restore() { ov off; anim_restore; dsp 'hl.dsp.focus({workspace = 1})'; hyprwall_resume; }
trap restore EXIT
hyprwall_pause

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5
warp 2500 430; sleep 0.5

dsp 'hl.dsp.focus({workspace = 3})'; sleep 0.6
fixture_kitty Y13AWAY $FX $FY $FW $FH '#ff00ff' 'clear; sleep infinity' || exit 1
dsp 'hl.dsp.focus({workspace = 5})'; sleep 0.6
fixture_kitty Y13HOME $FX $FY $FW $FH '#00c000' 'clear; sleep infinity' || exit 1
dsp 'hl.dsp.focus({workspace = 5})'; sleep 1.0
anim_slow $SLOW || exit 1

ov on; sleep 2.2
ydotool type 'Y13'; sleep 8.0
grim "$OUT/t000.png"
ydotool type 'HOME'
for i in 1 2 3 4 5 6 7 8 9 10 12 15 20 30; do
    grim "$OUT/t$(printf %03d $i).png"
    sleep 0.18
done
ov off; sleep 1.5

python3 - "$OUT" <<'PY'
import sys, glob, os
import numpy as np
from PIL import Image
for p in sorted(glob.glob(sys.argv[1] + "/*.png")):
    a = np.asarray(Image.open(p).convert("RGB")).astype(int)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    m = (r > 110) & (b > 110) & (g < 90) & (r - g > 60) & (b - g > 60)
    n = int(m.sum())
    if n:
        ys, xs = np.nonzero(m)
        print("%-10s magenta %7d  x %4d..%-4d y %4d..%-4d" % (os.path.basename(p), n, xs.min(), xs.max(), ys.min(), ys.max()))
    else:
        print("%-10s magenta       0" % os.path.basename(p))
PY
echo PROBE3_OK
