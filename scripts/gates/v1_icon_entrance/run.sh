#!/usr/bin/env bash
# v1_icon_entrance -- V1 (user, 2026-08-17): the app icon on a window tile does
# not just fade in with the overview, it GROWS.
#
#   "Start of animation - size 0. End of overview animation - whatever size the
#    icons in the bottom middle of the windows end up at. So both fade and grow."
#
# TWO FILMS, because the second is the one that catches the wrong architecture:
#   P1 OPEN      a clean open. The icon must start at nothing, grow
#                monotonically, decelerate, never pass its resting size, and be
#                finished by the time the overview is -- all read off the same
#                film, with the TILE as the clock (its drawn box rides the same
#                open progress, so the frame it stops is the frame the overview
#                settles).
#   P2 REVERSAL  an open interrupted by a close a quarter of a second in. An
#                icon on its own timeline keeps growing, or pops, while the
#                overview is already leaving; one that rides the overview's
#                progress comes straight back down through the same sizes. This
#                is the arm that would have caught a second clock.
#
# THE OVERVIEW'S OPEN IS NOT SLOWED BY anim_scale. anim_scale divides
# Config::animElapsedMs, which drives the hand-rolled eases (flights, reflow,
# hover); the open/close are Hyprland animated variables clocked by
# plugin:hyprdrive:open_speed / close_speed in tenths of a second. So the film
# is slowed with THOSE, at their ceiling of 20 = 2 s, which buys ~70 frames of
# open on this guest's capture rate.
#
# MEASURED, both halves on the same rig and the same session (zrig/v1/):
#                          first icon on film    ramp frames   reaches resting
#   before (fade only)     25 of 68 px (0.37)          2       8 frames in
#   with the grow           6 of 68 px (0.09)         22      48 frames in
# and on the reversal, up-ramp/down-ramp 1/0 frames before, 7/22 after. The
# "before" numbers are not zero because a full-size icon fading up crosses the
# mask's threshold over two frames; that residue is why the start arm is set at
# a quarter of resting rather than at nothing.
#
# THE FIXTURE IS SIZED FOR A CONSTANT RESTING ICON. The icon side is
# clamp(shortSide(tile) * 0.20, 28, 72): a tile whose short side stays above
# 360 px through the whole open is clamped at 72 the whole way, so "resting
# size" is one number and a shrinking tile cannot masquerade as a shrinking
# icon. 1200x900 drawn at overview scale 0.82 keeps the short side above 700.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=${RIG_EVIDENCE:-/mnt/host/zrig}/v1_icon; mkdir -p "$OUT"
rm -rf "$OUT/open" "$OUT/reverse"; mkdir -p "$OUT/open" "$OUT/reverse"
rm -f "$OUT"/*.mp4
FAIL=0

command -v wf-recorder >/dev/null || { echo "FAIL no wf-recorder"; exit 1; }
command -v ffmpeg      >/dev/null || { echo "FAIL no ffmpeg"; exit 1; }

gate_slate v1_icon_entrance >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }
[ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_pause 30min

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5

headless_on || exit 1
v1_stop() { pkill -x wf-recorder >/dev/null 2>&1; }
speed_restore() { cfg_ov 'open_speed=2.6'; cfg_ov 'close_speed=1.9'; }
trap 'v1_stop; ov off; speed_restore; headless_off; hyprwall_resume' EXIT

dsp "hl.dsp.focus({monitor = \"$RIG_MON\"})"; sleep 0.4
dsp 'hl.dsp.focus({workspace = 3})'; sleep 0.6
# THE FIXTURE CLASS IS `kitty`, ON PURPOSE. TileChrome draws the icon that
# AppSearch::iconForClass resolves for the window's class, and an invented class
# resolves to nothing at all -- the first cut of this gate filmed 444 frames of a
# tile with no icon on it and graded them. y8's rule: assert the fixture owns
# what is being photographed.
fixture_kitty kitty 640 300 1200 900 '#ff00ff' 'clear; sleep infinity' || exit 1
dsp 'hl.dsp.focus({workspace = 3})'; sleep 1.0

# opt_want compares the getoption STRING ("20.000000"), which is not what a
# float key reads back as -- compare numerically, the way anim_slow does.
speed_want() { # speed_want KEY VALUE
    local rb
    rb=$(hyprctl getoption "$1" | head -1 | awk '{print $2}')
    awk -v a="${rb:-x}" -v b="$2" 'BEGIN{exit (a+0==b+0)?0:1}' \
        || { echo "rig: $1 read back '$rb', wanted $2" >&2; return 1; }
}

cfg_ov 'open_speed=20'; cfg_ov 'close_speed=20'; sleep 0.6
speed_want $RIG_KEY:open_speed 20  || { echo "FAIL open_speed did not take -- the film would be 260 ms long"; exit 1; }
speed_want $RIG_KEY:close_speed 20 || { echo "FAIL close_speed did not take"; exit 1; }

film() { # film NAME SCRIPT...
    local name=$1; shift
    wf-recorder -o "$RIG_MON" -f "$OUT/$name.mp4" -r 60 >"$OUT/$name-wfr.log" 2>&1 &
    local wfr=$!
    sleep 1.5
    "$@"
    kill -INT $wfr 2>/dev/null; wait $wfr 2>/dev/null || true
    sleep 1
    [ -s "$OUT/$name.mp4" ] || { echo "FAIL wf-recorder produced no film for $name"; exit 1; }
    ffmpeg -v error -i "$OUT/$name.mp4" "$OUT/$name/f%04d.png" </dev/null \
        || { echo "FAIL could not extract $name frames"; exit 1; }
}

do_open()    { ov on;  sleep 4.5; }
do_reverse() { ov on;  sleep 0.25; ov off; sleep 4.5; }

echo "--- P1 OPEN (open_speed 20 = 2 s)"
film open do_open
python3 scripts/v1_icon_gate.py open "$OUT/open" ${V1_DUMP:+--dump} || FAIL=1

ov off; sleep 2.5

echo "--- P2 REVERSAL (close issued 250 ms into the open)"
film reverse do_reverse
python3 scripts/v1_icon_gate.py reverse "$OUT/reverse" ${V1_DUMP:+--dump} || FAIL=1

ov off; speed_restore
echo
[ $FAIL = 0 ] && echo "PASS v1_icon_entrance" || echo "FAIL v1_icon_entrance"
exit $FAIL
