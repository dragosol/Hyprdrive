#!/usr/bin/env bash
# v1_icon_entrance -- V1 (user, 2026-08-17): the app icon on a window tile does
# not just fade in with the overview, it GROWS.
#
#   "Start of animation - size 0. End of overview animation - whatever size the
#    icons in the bottom middle of the windows end up at. So both fade and grow."
#
# TWO FILMS:
#   P1 OPEN      a clean open. The icon must start at nothing, grow
#                monotonically, decelerate, never pass its resting size, and be
#                finished by the time the overview is -- all read off the same
#                film, with the TILE as the clock (its drawn box rides the same
#                open progress, so the frame it stops is the frame the overview
#                settles).
#   P2 REVERSAL  an open interrupted by a close a quarter of a second in. An
#                icon on its own timeline is at (or near) full size a quarter of
#                a second into a two-second open; one riding the overview's
#                progress is barely half that. This is the arm that catches a
#                second clock.
#
# THE OVERVIEW'S OPEN IS NOT SLOWED BY anim_scale. anim_scale divides
# Config::animElapsedMs, which drives the hand-rolled eases (flights, reflow,
# hover); the open/close are Hyprland animated variables clocked by
# plugin:hyprdrive:open_speed / close_speed in tenths of a second. So the film
# is slowed with THOSE, at their ceiling of 20 = 2 s.
#
# MEASURED, all four films on this fixture (zrig/v1/, zrig/v4/item0/):
#                          first icon on film    ramp        peak of a reversal
#   before (fade only)     25 of 68 px (0.37)     2 renders    0.985 of resting
#   with the grow          1-12 of 68 px          22-26        0.529-0.559
#
# THE FIXTURE IS SIZED FOR A CONSTANT RESTING ICON. The icon side is
# clamp(shortSide(tile) * 0.20, 28, 72): a tile whose short side stays above
# 360 px through the whole open is clamped at 72 the whole way, so "resting
# size" is one number and a shrinking tile cannot masquerade as a shrinking
# icon. 1200x900 drawn at overview scale 0.82 keeps the short side above 700.
#
# ---------------------------------------------------------------------------
# V4 (2026-08-18): THE RATE IS MEASURED, AND A THIN FILM IS A RIG FAULT.
#
# wf-recorder is ASKED for `-r 60`; its log then reports 60 whatever happened.
# Two separate lies live in that number and this gate believed both:
#   * the container's real rate is nb_frames/duration -- ffprobe, below, and it
#     is handed to the grader, which expresses every threshold in ms;
#   * the `fps=60` filter DUPLICATES frames the compositor never drew, so a
#     frame count is not an evidence count. The grader counts RENDERS (frames
#     on which the tile's drawn width advanced) and refuses to grade a span
#     that has too few, reporting RIG instead of FAIL.
# The grader exits 3 for RIG. P2 is refilmed up to V1_TRIES times before that
# verdict is accepted, because a thin film is usually a busy guest and not a
# broken one -- on 2026-08-18 a runaway xdg-desktop-portal-hyprland pegged at
# 107% CPU for five hours was starving the compositor's render loop, and the
# only symptom anywhere was this gate.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=${RIG_EVIDENCE:-/mnt/host/zrig}/v1_icon; mkdir -p "$OUT"
rm -rf "$OUT/open" "$OUT/reverse"; mkdir -p "$OUT/open" "$OUT/reverse"
rm -f "$OUT"/*.mp4
FAIL=0; RIG=0
V1_TRIES=${V1_TRIES:-3}

command -v wf-recorder >/dev/null || { echo "FAIL no wf-recorder"; exit 1; }
command -v ffmpeg      >/dev/null || { echo "FAIL no ffmpeg"; exit 1; }
command -v ffprobe     >/dev/null || { echo "FAIL no ffprobe -- the film's rate cannot be measured"; exit 1; }

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

# THE FILM'S OWN RATE, off the container. nb_frames/duration, never `-r`.
# BY KEY, not by position: ffprobe prints -show_entries fields in ITS OWN order
# (the order they sit in the stream struct), not the order they were asked for,
# so `-of csv` and $1/$2 silently computed the reciprocal -- 0.0166 fps, which
# the grader then correctly refused to believe.
measured_fps() { # measured_fps FILM
    ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames,duration \
            -of default=noprint_wrappers=1 "$1" 2>/dev/null \
        | awk -F= '$1=="duration"{d=$2} $1=="nb_frames"{n=$2}
                   END { if (d+0 > 0 && n+0 > 0) printf "%.4f", n/d }'
}

film() { # film NAME SCRIPT...
    local name=$1; shift
    rm -rf "$OUT/$name"; mkdir -p "$OUT/$name"; rm -f "$OUT/$name.mp4"
    wf-recorder -o "$RIG_MON" -f "$OUT/$name.mp4" -r 60 >"$OUT/$name-wfr.log" 2>&1 &
    local wfr=$!
    sleep 1.5
    "$@"
    kill -INT $wfr 2>/dev/null; wait $wfr 2>/dev/null || true
    sleep 1
    [ -s "$OUT/$name.mp4" ] || { echo "FAIL wf-recorder produced no film for $name"; exit 1; }
    ffmpeg -v error -i "$OUT/$name.mp4" "$OUT/$name/f%04d.png" </dev/null \
        || { echo "FAIL could not extract $name frames"; exit 1; }
    FPS=$(measured_fps "$OUT/$name.mp4")
    [ -n "$FPS" ] || { echo "FAIL could not measure the rate of $name.mp4"; exit 1; }
}

do_open()    { ov on;  sleep 4.5; }
do_reverse() { ov on;  sleep 0.25; ov off; sleep 4.5; }

REST="$OUT/resting.txt"; rm -f "$REST"

echo "--- P1 OPEN (open_speed 20 = 2 s)"
film open do_open
echo "    film: $(ls "$OUT/open" | wc -l) frames, measured ${FPS} fps"
python3 scripts/v1_icon_gate.py open "$OUT/open" --fps "$FPS" --write-resting "$REST" ${V1_DUMP:+--dump}
case $? in 0) ;; 3) RIG=1 ;; *) FAIL=1 ;; esac

ov off; sleep 2.5

# P1 is the only place the resting size can be measured -- P2's open is cut off
# a quarter of a second in and never reaches it.
RESTW=$(cat "$REST" 2>/dev/null || true)

echo "--- P2 REVERSAL (close issued 250 ms into the open)"
P2RC=3
for try in $(seq 1 "$V1_TRIES"); do
    [ "$try" = 1 ] || echo "    ...the film was too thin to grade; refilming (attempt $try of $V1_TRIES)"
    film reverse do_reverse
    echo "    film: $(ls "$OUT/reverse" | wc -l) frames, measured ${FPS} fps"
    python3 scripts/v1_icon_gate.py reverse "$OUT/reverse" --fps "$FPS" \
            ${RESTW:+--resting "$RESTW"} ${V1_DUMP:+--dump}
    P2RC=$?
    [ $P2RC = 3 ] || break
    ov off; sleep 2.0
done
case $P2RC in 0) ;; 3) RIG=1 ;; *) FAIL=1 ;; esac

ov off; speed_restore
echo
if [ $FAIL != 0 ]; then
    echo "FAIL v1_icon_entrance"
    exit 1
fi
if [ $RIG != 0 ]; then
    # NOT a pass and NOT a fail: the film does not contain the measurement.
    # suite.sh reads 3 as SKIP and the log says which arm and why.
    echo "RIG v1_icon_entrance -- the compositor did not draw enough frames to grade a"
    echo "RIG decisive arm, after $V1_TRIES attempts. This is the rig, not the build:"
    echo "RIG check for a process eating a core (xdg-desktop-portal-hyprland has done it)"
    echo "RIG before reading anything into it."
    exit 3
fi
echo "PASS v1_icon_entrance"
exit 0
