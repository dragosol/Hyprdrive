#!/usr/bin/env bash
# v2_super_pill -- V11_SPEC V2 (user, 2026-08-17), the PIXEL half.
#
#   "Hold SUPER -> each window grows a pill: 3 buttons (minimize, maximize,
#    close), inherited blur/frost, STRADDLING the window's top-right corner --
#    partially overhanging, 'not entirely over the window... but not entirely
#    outside of it'. Release SUPER -> pill leaves (exit accelerates per law)."
#
# FOUR ARMS. What each one is for, and how each one fails on the parent build:
#
#   P1 STRADDLE   a no-SUPER frame, a SUPER frame, a no-SUPER frame. The middle
#                 one must grow a capsule ON the fixture's top-right corner, and
#                 the straddle is graded as FOUR INEQUALITIES against that
#                 corner -- some of the blob above the top edge and some below,
#                 some of it past the right edge and some inside. A pill drawn
#                 wholly inside the corner and a pill drawn wholly outside it
#                 fail on different numbers, so the arm cannot be satisfied by
#                 "something appeared near there".
#                 PARENT: no pill exists, so there is no blob at all. RED.
#
#   P2 ABSENT     the two control frames against each other. Nothing that is
#                 not the clock may differ between "before SUPER" and "after
#                 SUPER was released" -- which is the exit half of the claim,
#                 measured rather than assumed. Green on the parent by absence,
#                 and it is here as the regression guard on P1's own controls:
#                 if it ever reds, P1's noise mask was doing the work.
#
#   P3 MOTION     one film of a full press-and-hold-and-release, graded inside
#                 the pill's own box (the window under it is a kitty holding a
#                 cleared screen and the wallpaper is pinned, so in there the
#                 pill is the only thing that changes and no mask is needed).
#                 The entrance must fit V2's own 150 ms budget and the exit must
#                 be 20-30% shorter, which is the house rule.
#                 SLOWED 10x through anim_scale, because 140 ms is eight frames
#                 at this guest's capture rate and a span measured in eight
#                 frames is measured to +-12%. animElapsedMs is the ONE place
#                 the plugin reads elapsed time, so the slowdown reaches the
#                 pill's ease and nothing else has to be edited; the budget is
#                 scaled with it and the arm is still grading 150 ms.
#                 PARENT: nothing ever appears in the box. RED.
#
#   P4 OVERVIEW   the tile hover, with the cursor HELD STILL across three shots
#                 so the blow-up, the caption and the tile itself are identical
#                 in all of them and the only variable is SUPER. The verdict is
#                 a WIDTH: X55's close-X is a disc of at most 32 px and the
#                 capsule is 112, so "the chrome on the corner got three times
#                 wider" cannot be produced by anything but the swap.
#                 PARENT: SUPER changes nothing in the overview. RED.
#
# THE FIXTURE IS kitty (standing rule -- an opaque app is what lets a frost
# check mean anything, and foot has no per-window opaque switch), placed
# explicitly at a size that keeps its corner clear of the shell's bar and of the
# dock's autohide edge, because all windows float here and sizes leak between
# rigs.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=${RIG_EVIDENCE:-/mnt/host/zrig}/v2/pill; mkdir -p "$OUT"
rm -rf "$OUT/film"; mkdir -p "$OUT/film"
rm -f "$OUT"/*.png "$OUT"/*.mp4
FAIL=0

command -v wf-recorder >/dev/null || { echo "FAIL no wf-recorder"; exit 1; }
command -v ffmpeg      >/dev/null || { echo "FAIL no ffmpeg"; exit 1; }

gate_slate v2_super_pill >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }
[ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_pause 30min

headless_on || exit 1
trap 'ydotool key 125:0 >/dev/null 2>&1; pkill -x wf-recorder >/dev/null 2>&1; pkill -x kitty 2>/dev/null; anim_restore; ov_off_settled; headless_off; hyprwall_resume' EXIT

FX=600; FY=430; FW=1100; FH=700
# Dock.cpp's numbers, predicted rather than read back -- a rig that asked the
# plugin where it drew could never catch a layout bug [x24_dock_click.sh:4-8].
#   capsule  W = 3*26 + 2*8 + 2*9 = 112     H = 26 + 2*7 = 40
#   straddle right edge = FX+FW + 26*0.5    centre line = FY
PW=112; PH=40
PX=$(( FX + FW - PW + 13 )); PY=$(( FY - PH/2 ))

pkill -x kitty 2>/dev/null; sleep 1
fixture_kitty V2PILL $FX $FY $FW $FH '#1030c0' 'clear; sleep infinity' || exit 1
sleep 1
# Out of every hit area, and out of the dock's autohide barrier at the bottom.
warp 200 900; sleep 0.6

echo "  fixture $FX,$FY ${FW}x${FH}   predicted capsule $PX,$PY ${PW}x${PH}"

############################################################ P1 / P2
echo "--- P1 STRADDLE + P2 ABSENT"
grim "$OUT/a-ctrl0.png"
sleep 0.4
ydotool key 125:1; sleep 0.8
grim "$OUT/b-super.png"
ydotool key 125:0; sleep 1.0
grim "$OUT/c-ctrl1.png"

for f in a-ctrl0 b-super c-ctrl1; do
    [ -s "$OUT/$f.png" ] || { echo "FAIL grim wrote nothing for $f -- capture pipeline is down"; exit 1; }
done

python3 scripts/v2_pill_gate.py straddle "$OUT/a-ctrl0.png" "$OUT/b-super.png" "$OUT/c-ctrl1.png" $FX $FY $FW $FH || FAIL=1
# The controls against a THIRD no-SUPER frame, so "nothing is there" is graded
# with a bracket of its own rather than against one arbitrary frame.
sleep 0.4
grim "$OUT/d-ctrl2.png"
python3 scripts/v2_pill_gate.py absent "$OUT/a-ctrl0.png" "$OUT/c-ctrl1.png" "$OUT/d-ctrl2.png" "released" || FAIL=1

############################################################ P3
echo "--- P3 MOTION (anim_scale 10)"
anim_slow 10 || { echo "FAIL anim_scale did not take -- the film would be 8 frames long"; exit 1; }

wf-recorder -o "$RIG_MON" -f "$OUT/motion.mp4" -r 60 >"$OUT/motion-wfr.log" 2>&1 &
WFR=$!
sleep 1.5
ydotool key 125:1
sleep 2.5
ydotool key 125:0
sleep 2.5
kill -INT $WFR 2>/dev/null; wait $WFR 2>/dev/null || true
sleep 1
[ -s "$OUT/motion.mp4" ] || { echo "FAIL wf-recorder produced no film"; exit 1; }
ffmpeg -v error -i "$OUT/motion.mp4" "$OUT/film/f%04d.png" </dev/null || { echo "FAIL could not extract frames"; exit 1; }

# THE FRAME RATE IS MEASURED, NOT ASSUMED. wf-recorder was asked for 60 and this
# guest's virgl cannot always give it -- the first run of this arm produced 339
# frames over 7.5 s, i.e. 45 fps, and grading those at a nominal 60 would have
# reported every span a third short. Duration and frame count come off the file.
FRAMES=$(ls "$OUT/film" | wc -l)
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/motion.mp4")
FPS=$(awk -v n="$FRAMES" -v d="${DUR:-0}" 'BEGIN{ printf "%.3f", (d>0.1)? n/d : 60 }')
echo "  film $FRAMES frames over ${DUR}s -> ${FPS} fps"

# 150 ms of budget, x10 because animElapsedMs is running at a tenth speed.
python3 scripts/v2_pill_gate.py motion "$OUT/film" $PX $PY $PW $PH 1500 "$FPS" || FAIL=1
anim_restore; sleep 0.5

############################################################ P4
echo "--- P4 OVERVIEW hover: pill, not close-X"
ov on; sleep 3
warp 120 1450; sleep 1.2      # off every tile: nothing hovered, nothing grown
grim "$OUT/ov-locate.png"
TILE=$(python3 scripts/x43_tilebox.py "$OUT/ov-locate.png" blue 2>&1)
echo "  $TILE"
TX1=$(echo "$TILE" | sed -n 's/.*x=\[[0-9]*,\([0-9]*\)\].*/\1/p')
TY0=$(echo "$TILE" | sed -n 's/.*y=\[\([0-9]*\),[0-9]*\].*/\1/p')
if [ -z "${TX1:-}" ] || [ -z "${TY0:-}" ]; then
    echo "FAIL could not locate the fixture tile in the overview -- the arm has nothing to hover"
    FAIL=1
else
    # THE TILE'S TOP-RIGHT CORNER, which is where the close-X is centred (X55,
    # CLOSE_INSET 0) and where the capsule's own CLOSE button lands. One point
    # that is a live hit target in BOTH builds, so the hover keep-alive holds
    # with and without SUPER and the three shots differ in nothing else.
    warp_or_die "$TX1" "$TY0"
    sleep 1.6                  # HOVER_IN_MS 200 + the close-X's own fade
    grim "$OUT/e-ov-x.png"
    sleep 0.4
    ydotool key 125:1; sleep 1.0
    grim "$OUT/f-ov-pill.png"
    ydotool key 125:0; sleep 1.2
    grim "$OUT/g-ov-x2.png"
    python3 scripts/v2_pill_gate.py overview "$OUT/e-ov-x.png" "$OUT/f-ov-pill.png" "$OUT/g-ov-x2.png" || FAIL=1
fi
ov_off_settled

alive_or_die "after the pill arms"
echo
[ $FAIL = 0 ] && echo "PASS v2_super_pill" || echo "FAIL v2_super_pill"
exit $FAIL
