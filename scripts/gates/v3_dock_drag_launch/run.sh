#!/usr/bin/env bash
# v3_dock_drag_launch -- V11_SPEC V3 (2026-08-17):
#
#   "Drag an icon OFF the dock and drop it (a) anywhere on the active desktop ->
#    launch on the active workspace; (b) onto any workspace card in the overview
#    strip -> launch on THAT workspace. [...] a drop that misses both targets
#    cancels (near-miss rules from X-series apply)."
#
# FOUR ARMS. What each proves, and how each falls on the parent build:
#
#   A DESKTOP    overview CLOSED. Press the dock's kitty cell, walk to the
#                middle of the screen, release. A kitty must appear ON THE
#                DESKTOP BEING VIEWED and the session must not move.
#                PARENT: the release off the pill is X32's cancel -- it resets
#                the drag and does nothing at all. Nothing spawns. RED.
#
#   B CARD       overview OPEN, viewing desktop 1, a card for desktop 3 in the
#                strip. Same drag, released on that card. A kitty must appear on
#                DESKTOP 3, the active desktop must still be 1, and both
#                fixtures must be where they were -- SILENT is the claim, and a
#                claim about what did NOT happen needs the untouched controls.
#                PARENT: same cancel. Nothing spawns. RED.
#
#   C NEARMISS   the same overview, released ~140 px below the strip band: on no
#                card, and not on the pill either. Two halves.
#                STATE  nothing spawns and nothing moves.  Green on the parent
#                       by absence -- doing nothing also spawns nothing, which
#                       is exactly why this half is not the whole arm.
#                FLIGHT the icon under the pointer FLIES HOME. Filmed at
#                       anim_scale 10 (the return is 220 ms, which is thirteen
#                       frames at this guest's capture rate) and graded with a
#                       control frame on either side of the measured one: PARKED
#                       says an icon is drawn under the pointer while the drag
#                       is held, TRAVEL says it is between the drop point and
#                       the dock a moment after the release.
#                       PARENT: nothing is ever drawn under the pointer, so
#                       PARKED measures 0 px against a 500 px floor. RED.
#
#   D CLICK      THE REGRESSION GUARD, and it is deliberately green on both
#                builds. Every dock gesture now goes through one resolver
#                (Drop::resolveIcon), and the highest-risk edge of that is the
#                first rung: a press and release at the SAME point must still be
#                a CLICK. Get that wrong and every dock click launches a second
#                copy of the app instead of minimizing it. x24, y4_click_
#                semantics, v6_dock_ws_scope, y8_bounce_once and
#                x32_showapps_fresh all press the pill and all require the click
#                to act, so the suite covers this five times over -- it is here
#                as well because those five would report it as five unrelated
#                failures a long way from the cause.
#
# THE FIXTURE IS PLAIN `kitty` (V6's reason: a launch needs the dock item to
# resolve to a real desktop entry, and a private class provides none), and the
# AWAY fixture is magenta so the strip locator has something saturated to find.
# The suite pins wp17, which is greyscale, so nothing but the fixture can
# satisfy a saturation mask -- see scripts/v3_drag_gate.py.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

OUT=${RIG_EVIDENCE:-/mnt/host/zrig}/v3/gate; mkdir -p "$OUT"
rm -rf "$OUT/film"; mkdir -p "$OUT/film"
rm -f "$OUT"/*.png "$OUT"/*.mp4
LOG=$OUT/gate.log; : > "$LOG"
FAIL=0
bad() { echo "FAIL $*" | tee -a "$LOG"; FAIL=1; }
say() { echo "$*" | tee -a "$LOG"; }

WS_HOME=1
WS_AWAY=3

command -v wf-recorder >/dev/null || { echo "FAIL no wf-recorder"; exit 1; }
command -v ffmpeg      >/dev/null || { echo "FAIL no ffmpeg"; exit 1; }

gate_slate v3_dock_drag_launch >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }
[ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_pause 30min

# ON THE HEADLESS OUTPUT. Virtual-1 draws ~1fps while no viewer is attached to
# the VM, so both halves of this gate would be measuring a stale frame: arm B
# locates its target in a screenshot, and arm C's whole verdict is a film.
headless_on || exit 1

# The cell predictor models RUNNING CLASSES only -- favourites, trash and the
# apps button are pinned items it cannot model, and autohide keeps the pill off
# screen. Same config every other dock gate runs under.
dock_test_cfg()    { cfg_dock "autohide=false, show_favorites=false, show_trash=false, show_mounts=false, show_apps_button=false"; }
dock_default_cfg() { cfg_dock "autohide=true, show_favorites=true, show_trash=true, show_mounts=false, show_apps_button=true"; }

cleanup() {
    pkill -x wf-recorder 2>/dev/null
    pkill -x kitty 2>/dev/null
    anim_restore
    dock_default_cfg
    dsp "hl.dsp.focus({workspace = 1})"
    return 0
}
# headless_off closes the overview FIRST and puts Virtual-1 back; it must run
# after the fixtures are gone and before the wallpaper timer comes back.
trap 'cleanup; headless_off; [ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_resume' EXIT

# --------------------------------------------------------------- helpers --
kitties()  { hyprctl clients -j | python3 -c "
import json,sys
print(len([c for c in json.load(sys.stdin) if c.get('class')=='kitty']))"; }
activews() { hyprctl monitors -j | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['activeWorkspace']['id'])"; }

# "WORKSPACE X,Y WxH" for a titled fixture, or "GONE" -- v6's reader, so an
# "untouched" control is a geometry rather than "still exists".
win() { hyprctl clients -j | python3 -c "
import json,sys
t=sys.argv[1]
for c in json.load(sys.stdin):
    if c.get('title')==t:
        print('%s %s,%s %sx%s' % (c['workspace']['name'], c['at'][0], c['at'][1], c['size'][0], c['size'][1])); break
else:
    print('GONE')" "$1"; }

# The window that is neither fixture: what a drop launched, and where.
launched() { hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('class')=='kitty' and c.get('title') not in ('V3HOME','V3AWAY'):
        print('%s %s' % (c['workspace']['name'], c['title'])); break
else:
    print('NONE')"; }

spawn_at() { # spawn_at WS TITLE COLOUR X Y W H
    local ws=$1 title=$2 colour=$3 x=$4 y=$5 w=$6 h=$7
    dsp "hl.dsp.focus({workspace = $ws})"; sleep 0.8
    setsid kitty -c NONE --title "$title" -o background="$colour" -o background_opacity=1.0 \
        -o confirm_os_window_close=0 --hold sh -c 'sleep 3600' >/dev/null 2>&1 </dev/null &
    sleep 2.4
    hyprctl eval "hl.dispatch(hl.dsp.window.resize({x = $w, y = $h, relative = false})) hl.dispatch(hl.dsp.window.move({x = $x, y = $y, relative = false})) return 1" >/dev/null 2>&1
    sleep 0.8
    [ "$(win "$title")" != GONE ] || { echo "rig: fixture $title did not map on desktop $ws" >&2; return 1; }
}

# THE DRAG. Press on a point, walk to another in twelve steps, release there.
# Twelve because one warp is a teleport and the drag threshold is measured on
# the FIRST motion past it -- and because the ghost has to be given frames to be
# drawn in, which is what arm C photographs.
DRAG_HOLD=${V3_DRAG_HOLD:-0.4}
drag_to() { # drag_to X0 Y0 X1 Y1 [SHOT]
    local x0=$1 y0=$2 x1=$3 y1=$4 shot=${5:-} i
    warp_or_die "$x0" "$y0"; sleep 0.5
    ydotool click 0x40
    for i in $(seq 1 12); do
        warp $(( x0 + (x1 - x0) * i / 12 )) $(( y0 + (y1 - y0) * i / 12 ))
        sleep 0.05
    done
    sleep "$DRAG_HOLD"
    [ -n "$shot" ] && grim "$shot" 2>/dev/null
    ydotool click 0x80
}

# The dock cell, re-predicted before EVERY gesture: the pill's contents change
# as windows come and go, and a hit target computed before the previous arm is
# the standing trap here [y4_cycle.sh:32-35].
cell() {
    local cx cy
    read -r cx cy <<< "$(dock_cell kitty)"
    [ -n "${cx:-}" ] || { echo "rig: no dock cell predicted for kitty" >&2; return 1; }
    echo "$cx $cy"
}

############################################################################
pkill -x kitty 2>/dev/null; sleep 1
dock_test_cfg; sleep 0.8
opt_want "$RIG_KEY:dock:autohide" false || { echo "FAIL dock config did not take"; exit 1; }

spawn_at $WS_HOME V3HOME '#101820' 300 700 900 560 || exit 1
spawn_at $WS_AWAY V3AWAY '#ff00ff' 300 300 900 560 || exit 1
dsp "hl.dsp.focus({workspace = $WS_HOME})"; sleep 1.0

HOME0=$(win V3HOME); AWAY0=$(win V3AWAY)
say "  base   HOME: $HOME0   AWAY: $AWAY0   kitties=$(kitties)   active=$(activews)"
[ "${HOME0%% *}" = "$WS_HOME" ] || { echo "FAIL fixture HOME is on ${HOME0%% *}"; exit 1; }
[ "${AWAY0%% *}" = "$WS_AWAY" ] || { echo "FAIL fixture AWAY is on ${AWAY0%% *}"; exit 1; }

############################################################ A  DESKTOP
say "--- A DESKTOP: dock cell -> the middle of the screen, overview closed"
N0=$(kitties)
read -r CX CY <<< "$(cell)" || exit 1
say "    from $CX,$CY to 1280,800"
drag_to "$CX" "$CY" 1280 800 "$OUT/a-middrag.png"
sleep 5
alive_or_die "after the desktop drop"
N1=$(kitties); LA=$(launched); AW=$(activews)
say "    kitties $N0 -> $N1   new: $LA   active desktop: $AW"
[ "$N1" -gt "$N0" ] || bad "A -- nothing launched by a drop on the desktop (the parent's off-pill release is a bare cancel)"
[ "${LA%% *}" = "$WS_HOME" ] || bad "A -- the new window landed on '${LA%% *}', not the desktop it was dropped on ($WS_HOME)"
[ "$AW" = "$WS_HOME" ] || bad "A -- the drop moved the session to desktop $AW"

# Back to two fixtures for the arms that count.
hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('class')=='kitty' and c.get('title') not in ('V3HOME','V3AWAY') and c.get('pid',0)>0: print(c['pid'])" | xargs -r kill -9 2>/dev/null
sleep 1.5
[ "$(kitties)" = 2 ] || bad "A -- could not get back to two fixtures (have $(kitties))"

############################################################ B  CARD
say "--- B CARD: dock cell -> desktop $WS_AWAY's strip card, overview open"
ov on; sleep 3
grim "$OUT/b-overview.png" 2>/dev/null
[ -s "$OUT/b-overview.png" ] || { echo "FAIL grim wrote nothing -- capture pipeline is down"; exit 1; }
if ! read -r SX SY <<< "$(python3 scripts/v3_drag_gate.py strip "$OUT/b-overview.png" 2>>"$LOG")"; then
    bad "B -- could not locate desktop $WS_AWAY's card in the strip (is the overview open, is the plugin loaded?)"
    SX=""; SY=""
fi

if [ -n "${SX:-}" ]; then
    say "    strip card for desktop $WS_AWAY at $SX,$SY"
    N0=$(kitties)
    read -r CX CY <<< "$(cell)" || exit 1
    drag_to "$CX" "$CY" "$SX" "$SY" "$OUT/b-middrag.png"
    sleep 5
    alive_or_die "after the card drop"
    N1=$(kitties); LB=$(launched); AW=$(activews)
    HOME1=$(win V3HOME); AWAY1=$(win V3AWAY)
    say "    kitties $N0 -> $N1   new: $LB   active desktop: $AW"
    say "    HOME: $HOME1   AWAY: $AWAY1"
    [ "$N1" -gt "$N0" ] || bad "B -- nothing launched by a drop on a strip card"
    [ "${LB%% *}" = "$WS_AWAY" ] || bad "B -- the new window landed on '${LB%% *}', not the desktop whose card was dropped on ($WS_AWAY)"
    [ "$AW" = "$WS_HOME" ] || bad "B -- SILENT was the claim and the session moved to desktop $AW"
    [ "$HOME1" = "$HOME0" ] || bad "B -- the fixture on desktop $WS_HOME moved: '$HOME0' -> '$HOME1'"
    [ "$AWAY1" = "$AWAY0" ] || bad "B -- the fixture on desktop $WS_AWAY moved: '$AWAY0' -> '$AWAY1'"

    hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('class')=='kitty' and c.get('title') not in ('V3HOME','V3AWAY') and c.get('pid',0)>0: print(c['pid'])" | xargs -r kill -9 2>/dev/null
    sleep 1.5
fi

############################################################ C  NEARMISS
# 140 px below the mini the locator found. The strip cell is ~135 px tall and
# the mini sits inside it, so this is between 30 and 70 px below the band's
# outer edge -- X26 P2's near miss (28 px above the pill) in the other
# direction. The numbers are printed so the margin can be read off a log; if the
# strip band ever grows past them this arm goes RED (something launches), never
# quietly green.
if [ -n "${SX:-}" ]; then
    NMX=$SX; NMY=$(( SY + 140 ))
    say "--- C NEARMISS: dock cell -> $NMX,$NMY (below every card, off the pill)"
    anim_slow 10 || { echo "FAIL anim_scale did not take -- a 220ms return is 13 frames"; exit 1; }

    N0=$(kitties)
    read -r CX CY <<< "$(cell)" || exit 1

    wf-recorder -o "$RIG_MON" -f "$OUT/nearmiss.mp4" -r 60 >"$OUT/nearmiss-wfr.log" 2>&1 &
    WFR=$!
    sleep 1.5
    # A recorder that never started is a film that never existed, and the
    # `kill` at the other end would then be aimed at a pid the system is free
    # to have handed to something else.
    kill -0 "$WFR" 2>/dev/null || { echo "FAIL C -- wf-recorder did not start"; cat "$OUT/nearmiss-wfr.log"; exit 1; }
    T0=$(date +%s.%N)
    warp_or_die "$CX" "$CY"; sleep 0.5
    ydotool click 0x40
    for i in $(seq 1 12); do
        warp $(( CX + (NMX - CX) * i / 12 )) $(( CY + (NMY - CY) * i / 12 ))
        sleep 0.05
    done
    sleep 1.2                       # the icon parked under the pointer: P's frame
    REL=$(date +%s.%N)
    ydotool click 0x80
    sleep 4.5                       # the 220ms return, x10, then a settled tail
    kill -INT "$WFR" 2>/dev/null; wait "$WFR" 2>/dev/null || true
    sleep 1
    anim_restore; sleep 0.5

    alive_or_die "after the near miss"
    N1=$(kitties); LC=$(launched)
    HOME2=$(win V3HOME); AWAY2=$(win V3AWAY)
    say "    STATE  kitties $N0 -> $N1   new: $LC"
    [ "$N1" = "$N0" ] || bad "C STATE -- a drop that hit no card and no pill launched something ($LC)"
    [ "$LC" = NONE ]  || bad "C STATE -- an unexpected window exists after the near miss: $LC"
    [ "$HOME2" = "$HOME0" ] || bad "C STATE -- the fixture on desktop $WS_HOME moved: '$HOME0' -> '$HOME2'"
    [ "$AWAY2" = "$AWAY0" ] || bad "C STATE -- the fixture on desktop $WS_AWAY moved: '$AWAY0' -> '$AWAY2'"

    if [ ! -s "$OUT/nearmiss.mp4" ]; then
        bad "C FLIGHT -- wf-recorder produced no film"
    else
        ffmpeg -v error -i "$OUT/nearmiss.mp4" "$OUT/film/f%04d.png" </dev/null 2>>"$LOG" || bad "C FLIGHT -- could not extract frames"
        FRAMES=$(find "$OUT/film" -name 'f*.png' | wc -l)
        DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/nearmiss.mp4")
        # MEASURED, never assumed: wf-recorder is asked for 60 and this guest's
        # virgl does not always give it, and a span graded at a nominal rate is
        # a span reported short by whatever the shortfall was [v2_super_pill:126].
        FPS=$(awk -v n="$FRAMES" -v d="${DUR:-0}" 'BEGIN{ printf "%.3f", (d>0.1)? n/d : 60 }')
        RELS=$(awk -v a="$REL" -v b="$T0" 'BEGIN{ printf "%.3f", a-b+1.5 }')
        say "    film $FRAMES frames over ${DUR}s -> ${FPS} fps, release at ${RELS}s"
        # 220 ms of return, x10 because animElapsedMs is running at a tenth
        # speed. The grader's own status is what decides, not tee's -- a piped
        # verdict is the verdict of the last command in the pipe, which is how
        # a red arm reads green (this gate's second run said PASS while its own
        # log said FAIL TRAVEL).
        python3 scripts/v3_drag_gate.py flight "$OUT/film" "$FPS" "$RELS" "$NMX" "$NMY" "$CX" "$CY" 2200 >"$OUT/flight.txt" 2>&1
        FLIGHTRC=$?
        cat "$OUT/flight.txt" | tee -a "$LOG"
        [ $FLIGHTRC -eq 0 ] || bad "C FLIGHT -- the icon did not fly home"
    fi
fi
ov_off_settled

############################################################ D  CLICK
# The first rung of the resolver, on its own. Press and release on the same
# point with the overview closed: a CLICK, so the fixture on this desktop is
# minimized and NOTHING is launched. Green on both builds by design.
say "--- D CLICK: press and release on the cell is still a click, not a drop"
dsp "hl.dsp.focus({workspace = $WS_HOME})"; sleep 1.0
N0=$(kitties)
dock_click kitty >/dev/null 2>&1 || bad "D -- the dock click failed"
sleep 2.5
alive_or_die "after the click"
N1=$(kitties); HOME3=$(win V3HOME)
say "    kitties $N0 -> $N1   HOME: $HOME3"
[ "$N1" = "$N0" ] || bad "D -- a click on the cell LAUNCHED (the near-start rung of the resolver is broken: every dock click would now start a second copy)"
[ "${HOME3%% *}" = special:minimized ] || bad "D -- the click did not minimize the window on this desktop (HOME is on ${HOME3%% *})"

say
[ $FAIL -eq 0 ] && say "v3_dock_drag_launch PASS -- an icon dropped on a desktop launches there, on a card launches THERE silently, and a miss flies home"
exit $FAIL
