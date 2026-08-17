#!/usr/bin/env bash
# f3b_release -- OVERVIEW_CPP_SPEC 13.2 F3-b, the OUTBOUND half.
#
# "Applies symmetrically: pulling IN as the query narrows to a match, and
# releasing back OUT to its own desktop as the query stops matching." F3-b-ii
# then binds both directions: "it must have real interpolated frames the whole
# way. 'Fast' is not a licence to drop to one or two frames."
#
# THE FIXTURE IS THE MEASUREMENT. The promoted tile is appended AFTER the
# active desktop's own windows, so it is the RIGHTMOST tile in the row; and the
# survivor recentres LEFT-to-right as the grid closes up. Put the away window on
# a HIGHER-numbered desktop and its release therefore travels RIGHT, away from
# the survivor, and nothing ever occludes the thing being graded. With the away
# desktop on the LEFT (the obvious arrangement, and the one the fire's probe
# used) the outbound tile slides straight under the survivor and the pixel count
# collapses for reasons that have nothing to do with the animation.
#
# ANIM_SCALE 10, and the verdict is in FRAMES. The guest's present rate is not a
# constant; the film's timebase is. What the grader counts is how many frames the
# tile is on screen while travelling, which is a direct reading of how much of
# the release curve happens where the eye can see it.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=${RIG_EVIDENCE:-/mnt/host/zrig}/f3b_release; mkdir -p "$OUT"
FRAMES=$OUT/frames; rm -rf "$FRAMES"; mkdir -p "$FRAMES"
rm -f "$OUT/release.mp4"

# Frames, not milliseconds -- see the header. MEASURED at anim_scale 10 on a
# 60fps film, both halves of the A/B on the same session and the same wallpaper:
#   9c2742f (entrance curve on the exit)   travel  11 frames, span 1092 px
#   with the release on the house accel    travel  80 frames, span 1120 px
# Same distance, seven times the frames -- which is the defect exactly: the tile
# always travelled, it just did all of it in the first twelfth of the animation.
# 35 sits 3.2x above the defect and 2.3x below the fix.
MINFRAMES=${F3B_MINFRAMES:-35}
MINPX=${F3B_MINPX:-600}

command -v wf-recorder >/dev/null || { echo "FAIL no wf-recorder"; exit 1; }
command -v ffmpeg      >/dev/null || { echo "FAIL no ffmpeg"; exit 1; }

gate_slate f3b_release >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }
[ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_pause 30min

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5

headless_on || exit 1
f3b_stop() { pkill -x wf-recorder >/dev/null 2>&1; }
trap 'f3b_stop; ov off; anim_restore; headless_off; hyprwall_resume' EXIT

dsp "hl.dsp.focus({monitor = \"$RIG_MON\"})"; sleep 0.4

FX=760; FY=560; FW=900; FH=560
# AWAY on the HIGHER desktop: it is released to the RIGHT, away from the
# survivor. HOME is the active desktop, and is the liveness control -- if the
# query never reached the search bar it does not recentre either.
dsp 'hl.dsp.focus({workspace = 5})'; sleep 0.6
fixture_kitty F3BAWAY $FX $FY $FW $FH '#ff00ff' 'clear; sleep infinity' || exit 1
dsp 'hl.dsp.focus({workspace = 3})'; sleep 0.6
fixture_kitty F3BHOME $FX $FY $FW $FH '#00c000' 'clear; sleep infinity' || exit 1
dsp 'hl.dsp.focus({workspace = 3})'; sleep 1.0

anim_slow 10 || exit 1

ov on; sleep 2.5
ydotool type 'F3B'; sleep 5.0            # both match; the promotion settles

# The tile must BE there before the release can be graded -- assert the subject
# exists before filming it (y8's three wasted rounds).
grim "$OUT/settled.png" 2>/dev/null
python3 - "$OUT/settled.png" <<'PY' || { echo "FAIL the away tile never joined the grid -- rig fault, nothing to release"; exit 1; }
import sys, numpy as np
sys.path.insert(0, "scripts")
from PIL import Image
from blob import largest_of
im = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
r, g, b = im[:, :, 0], im[:, :, 1], im[:, :, 2]
m = (r > 110) & (b > 110) & (g < 90) & (r - g > 60) & (b - g > 60)
m[:450, :] = False
found = largest_of(m)
print("    settled away tile: %s" % (found,))
sys.exit(0 if found and found[4] >= 40000 else 1)
PY

wf-recorder -o "$RIG_MON" -f "$OUT/release.mp4" -r 60 >"$OUT/wfr.log" 2>&1 &
WFR=$!
sleep 2
ydotool type 'HOME'                       # F3BAWAY stops matching -> release
sleep 8
kill -INT $WFR 2>/dev/null; wait $WFR 2>/dev/null || true
sleep 1

ov off; anim_restore

[ -s "$OUT/release.mp4" ] || { echo "FAIL wf-recorder produced no film"; exit 1; }
ffmpeg -v error -i "$OUT/release.mp4" "$FRAMES/f%04d.png" </dev/null || { echo "FAIL could not extract frames"; exit 1; }

echo "--- F3-b OUTBOUND (film $(ls "$FRAMES" | wc -l) frames, anim_scale 10)"
python3 scripts/f3b_release_gate.py "$FRAMES" "$MINFRAMES" "$MINPX"
