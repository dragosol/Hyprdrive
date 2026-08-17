#!/usr/bin/env bash
# v6_dock_ws_scope -- V11_SPEC V6 (user amendment 2026-08-17): "if I have
# multiple windows of the same app e.g. nautilus open and i click its icon, it
# should only minimizes/maximizes the window in the current workspace."
#
# The X45/Y4 click ladder keeps its shape; its COUNT and TARGET SET are computed
# over the ACTIVE DESKTOP alone:
#     0 here -> launch here, regardless of what the app has elsewhere
#     1 here -> the existing minimize/restore toggle, on that one
#     N here -> the existing cycle, over those N
# and a minimized window counts toward the desktop it will come back to.
#
# STATE, NOT PIXELS. Every assertion is a workspace name or a geometry read out
# of `hyprctl clients -j`, so no wallpaper, frame rate or capture pipeline can
# enter the verdict -- and geometry is what makes "untouched" mean untouched
# rather than "still exists".
#
# FOUR ARMS, each with the OTHER desktop's window as its control:
#   SCOPE    one window on desktop A, one on desktop B, viewing A. The click
#            minimizes A's. B's window must be on B, at the same position and
#            size, afterwards.
#   RESTORE  the same click again brings A's window back to A at the geometry it
#            had before, B's still untouched. (The toggle has to survive being
#            scoped, or the feature has taken the app away with no way back.)
#   CYCLE    the ladder's third rung: a SECOND window on A, so the app has two
#            here and one there, and CTRL+click steps among the two. Three
#            clicks, re-aimed each time: every window it lands on must be one of
#            A's, and the session must still be on A. With three windows in the
#            cycle three clicks visit all three, so an un-scoped cycle CANNOT
#            avoid B's window -- which is why three and not two.
#   LAUNCH   walk to an EMPTY desktop C and click the same icon: a third window
#            appears ON C, and the session is still on C. Zero here means launch
#            here even though the app has two windows one desktop away.
#
# FAIL-ON-OLD, and the three discriminating arms fail by taking three
# different old branches (RESTORE is green on both builds by design -- it is
# the regression guard, not a discriminator):
#   SCOPE  the un-scoped ladder counts both windows, so the plain click is a
#          whole-app minimize (Dock.cpp Y4) and B's window goes to
#          `special:minimized` with A's.
#   CYCLE  the un-scoped cycle has three windows in its ring and three clicks
#          walk all of it, so it lands on B's window and activateWindow takes
#          the session to desktop B with it.
#   LAUNCH the un-scoped ladder sees visible windows with none on this desktop
#          and takes Z7's GO-THERE branch instead: it switches the session to
#          desktop A and focuses that window. No third window is ever launched.
#          V6 supersedes Z7 for this gesture -- both are the user's words, ten
#          days apart, and the later one is the one the dock obeys.
#
# THE FIXTURE IS PLAIN `kitty`, not a private class: the LAUNCH arm needs the
# dock item to resolve to a real desktop entry, and a class nothing provides has
# nothing to launch (the same reason y8_bounce_once spawns kitty). The windows
# are told apart by TITLE.
#
# LAPS: the whole four-arm sequence runs twice. A scoping bug that only shows
# up once the cycle memory or the minimize ledger has been through a round trip
# would pass a single lap.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

OUT=${RIG_EVIDENCE:-/mnt/host/zrig}/v6/gate; mkdir -p "$OUT"
LOG=$OUT/gate.log; : > "$LOG"
FAIL=0
bad() { echo "FAIL $*" | tee -a "$LOG"; FAIL=1; }
say() { echo "$*" | tee -a "$LOG"; }

WS_A=3
WS_B=5
WS_C=7
LAPS=${V6_LAPS:-2}

gate_slate v6_dock_ws_scope >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }
[ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_pause 30min

# The cell predictor models RUNNING CLASSES only: favourites, trash and the apps
# button are pinned items it cannot model, and autohide keeps the pill off
# screen. Same config the other dock gates run under; put it back afterwards.
dock_test_cfg()    { cfg_dock "autohide=false, show_favorites=false, show_trash=false, show_mounts=false, show_apps_button=false"; }
dock_default_cfg() { cfg_dock "autohide=true, show_favorites=true, show_trash=true, show_mounts=false, show_apps_button=true"; }

cleanup() {
    pkill -x kitty 2>/dev/null
    dock_default_cfg
    dsp "hl.dsp.focus({workspace = 1})"
    return 0
}
trap 'cleanup; [ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_resume' EXIT

# ---------------------------------------------------------------- fixtures --
# One window at a time, placed while it still owns the focus -- all windows
# float and sizes leak between rigs, so geometry is always set explicitly.
spawn_at() { # spawn_at WS TITLE X Y W H
    local ws=$1 title=$2 x=$3 y=$4 w=$5 h=$6
    dsp "hl.dsp.focus({workspace = $ws})"; sleep 0.8
    setsid kitty -c NONE --title "$title" -o background=#101820 -o background_opacity=1.0 \
        -o confirm_os_window_close=0 --hold sh -c 'sleep 3600' >/dev/null 2>&1 </dev/null &
    sleep 2.4
    hyprctl eval "$(cat <<LUA
hl.dispatch(hl.dsp.window.resize({x = $w, y = $h, relative = false}))
hl.dispatch(hl.dsp.window.move({x = $x, y = $y, relative = false}))
return 1
LUA
)" >/dev/null 2>&1
    sleep 0.8
    win "$title" >/dev/null || { echo "rig: fixture $title did not map on desktop $ws" >&2; return 1; }
    return 0
}

# "WORKSPACE X,Y WxH" for the window with this title, or "GONE".
win() { # win TITLE
    hyprctl clients -j | python3 -c "
import json,sys
t=sys.argv[1]
for c in json.load(sys.stdin):
    if c.get('title')==t:
        print('%s %s,%s %sx%s' % (c['workspace']['name'], c['at'][0], c['at'][1], c['size'][0], c['size'][1]))
        break
else:
    print('GONE'); sys.exit(1)
" "$1"
}

kitties() { hyprctl clients -j | python3 -c "
import json,sys
print(len([c for c in json.load(sys.stdin) if c.get('class')=='kitty']))"; }

# The window that is none of the fixtures, by title -- the LAUNCH arm's new one.
# V6A2 is in the exclusion list because the CYCLE arm before it spawns one; it
# is killed at the end of that arm, and naming it here means a kill that did not
# take shows up as "nothing launched" rather than as a false pass.
launched() {
    hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('class')=='kitty' and c.get('title') not in ('V6A','V6A2','V6B'):
        print('%s %s' % (c['workspace']['name'], c['title'])); break
else:
    print('NONE')"
}

activews() { hyprctl monitors -j | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['activeWorkspace']['id'])"; }

# The dock click. `dock_click` sweeps every non-kitty window first (the cell
# predictor works off running classes, so a stray window moves every icon), then
# predicts the class's cell and presses it.
# stdout is dropped (ydotool chatters the coordinates it lands on); a real
# failure comes back on stderr and through the exit code.
clickdock() { dock_click kitty >/dev/null || { echo "rig: dock click failed" >&2; return 1; }; sleep 2.5; }

# CTRL+click, re-aimed every time. Reusing a hit target computed before the
# first click is the standing trap here: the pill's contents can reorder under
# it and every later click lands on a neighbour [y4_cycle.sh:32-35].
#
# AND IT HAS A CLOCK. The cycle's window list is REMEMBERED for
# CYCLE_MEMORY_MS = 3000 (Dock.cpp), and a cycle whose memory has expired
# rebuilds the list and steps from index 0 again -- so clicks spaced further
# apart than that land on the SAME window every time and a live cycle reads as
# a dead one. Measured: the first cut of this arm ran ~3.2s per click (the
# `killothers` sweep and a 1.5s tail) and scored focus V6A2 V6A2 V6A2. No sweep
# (nothing spawns during the arm and the dock's contents are fixed), a short
# tail, and the interval is REPORTED so the arm can say "the rig was too slow"
# instead of blaming the build.
CYC_MS=0
ctrlclickdock() {
    local cx cy d t0 t1
    t0=$(date +%s%N)
    read -r cx cy <<< "$(dock_cell kitty)"
    [ -n "${cx:-}" ] || { echo "rig: no dock cell predicted for kitty" >&2; return 1; }
    warp_or_die "$cx" "$cy"
    ydotool key 29:1 >/dev/null 2>&1
    ydotool click 0x40 >/dev/null 2>&1
    for d in 2 -2 3 -1 0; do warp $((cx+d)) $((cy-d)) >/dev/null 2>&1; sleep 0.025; done
    ydotool click 0x80 >/dev/null 2>&1
    ydotool key 29:0 >/dev/null 2>&1
    sleep 0.8
    t1=$(date +%s%N)
    CYC_MS=$(( (t1 - t0) / 1000000 ))
}

focusedtitle() { hyprctl activewindow -j | python3 -c "
import json,sys
print(json.load(sys.stdin).get('title','(none)'))" 2>/dev/null; }

killtitle() { # killtitle TITLE
    hyprctl clients -j | python3 -c "
import json,sys
t=sys.argv[1]
for c in json.load(sys.stdin):
    if c.get('title')==t and c.get('pid',0)>0: print(c['pid'])" "$1" | xargs -r kill -9 2>/dev/null
    sleep 1.2
    return 0
}

############################################################################
pkill -x kitty 2>/dev/null; sleep 1
dock_test_cfg; sleep 0.8
opt_want "$RIG_KEY:dock:autohide" false || { echo "FAIL dock config did not take"; exit 1; }

for lap in $(seq 1 "$LAPS"); do
    say "===== lap $lap ====="
    pkill -x kitty 2>/dev/null; sleep 1.2

    spawn_at $WS_A V6A 300 200 900 560 || exit 1
    spawn_at $WS_B V6B 700 400 800 500 || exit 1
    dsp "hl.dsp.focus({workspace = $WS_A})"; sleep 1.0

    A0=$(win V6A); B0=$(win V6B)
    say "  base   A: $A0   B: $B0"
    [ "${A0%% *}" = "$WS_A" ] || { echo "FAIL fixture A is on ${A0%% *}, wanted $WS_A"; exit 1; }
    [ "${B0%% *}" = "$WS_B" ] || { echo "FAIL fixture B is on ${B0%% *}, wanted $WS_B"; exit 1; }
    [ "$(kitties)" = 2 ] || { echo "FAIL wanted exactly two kitty windows, have $(kitties)"; exit 1; }

    ############################################################ SCOPE
    clickdock || exit 1
    alive_or_die "after the scope click"
    A1=$(win V6A); B1=$(win V6B)
    say "  SCOPE  A: $A1   B: $B1"
    [ "${A1%% *}" = special:minimized ] \
        || bad "SCOPE lap$lap -- the click did not minimize the window on the desktop being viewed (A is on ${A1%% *})"
    [ "$B1" = "$B0" ] \
        || bad "SCOPE lap$lap -- the window on desktop $WS_B moved: '$B0' -> '$B1' (the un-scoped ladder minimizes the whole app)"

    ############################################################ RESTORE
    clickdock || exit 1
    alive_or_die "after the restore click"
    A2=$(win V6A); B2=$(win V6B)
    say "  RSTOR  A: $A2   B: $B2"
    [ "$A2" = "$A0" ] || bad "RESTORE lap$lap -- A came back as '$A2', was '$A0'"
    [ "$B2" = "$B0" ] || bad "RESTORE lap$lap -- the window on desktop $WS_B moved: '$B0' -> '$B2'"

    ############################################################ CYCLE
    spawn_at $WS_A V6A2 1400 250 700 480 || exit 1
    dsp "hl.dsp.focus({workspace = $WS_A})"; sleep 0.8
    SEEN=""; CYCWS=""; SLOW=0
    for i in 1 2 3; do
        ctrlclickdock || exit 1
        [ "$CYC_MS" -gt 2500 ] && SLOW=$CYC_MS
        F=$(focusedtitle); W=$(activews)
        SEEN="$SEEN $F"; CYCWS="$CYCWS $W"
    done
    alive_or_die "after the cycle clicks"
    DISTINCT=$(printf '%s\n' $SEEN | sort -u | wc -l)
    say "  CYCLE  focus:$SEEN   desktop:$CYCWS   distinct=$DISTINCT   click interval ${CYC_MS}ms"
    for F in $SEEN; do
        case "$F" in
            V6A|V6A2) ;;
            *) bad "CYCLE lap$lap -- the cycle reached '$F', which is not a window on desktop $WS_A (the un-scoped cycle has all three in its ring)" ;;
        esac
    done
    for W in $CYCWS; do
        [ "$W" = "$WS_A" ] || bad "CYCLE lap$lap -- the cycle took the session to desktop $W"
    done
    # Liveness, and the reason it is DISTINCT rather than "focus changed": with
    # the memory alive the cycle alternates over the two windows here, so three
    # clicks must show both of them. One title over three clicks is a cycle that
    # is not stepping -- and if the rig was the slow one, say THAT.
    if [ "$DISTINCT" -lt 2 ] && [ "$SLOW" != 0 ]; then
        bad "CYCLE lap$lap -- ABORT, the rig clicked every ${SLOW}ms against a 3000ms cycle memory: the cycle restarted each time and this arm measured the rig, not the build"
    elif [ "$DISTINCT" -lt 2 ]; then
        bad "CYCLE lap$lap -- three ctrl+clicks visited one window ($SEEN); a live cycle alternates over the two on this desktop"
    fi
    B4=$(win V6B)
    [ "$B4" = "$B0" ] || bad "CYCLE lap$lap -- the window on desktop $WS_B moved: '$B0' -> '$B4'"
    killtitle V6A2

    ############################################################ LAUNCH
    dsp "hl.dsp.focus({workspace = $WS_C})"; sleep 1.2
    [ "$(activews)" = "$WS_C" ] || { echo "FAIL could not get to the empty desktop $WS_C"; exit 1; }
    N0=$(kitties)
    clickdock || exit 1
    sleep 4.5                       # a cold kitty takes a moment to map
    alive_or_die "after the launch click"
    N1=$(kitties); L=$(launched); AW=$(activews)
    A3=$(win V6A); B3=$(win V6B)
    say "  LAUNCH kitties $N0 -> $N1   new: $L   active desktop: $AW"
    say "         A: $A3   B: $B3"
    [ "$N1" -gt "$N0" ] \
        || bad "LAUNCH lap$lap -- nothing launched on the empty desktop $WS_C (the un-scoped ladder takes Z7's go-there branch instead)"
    [ "$AW" = "$WS_C" ] \
        || bad "LAUNCH lap$lap -- the click moved the session to desktop $AW instead of acting on $WS_C (Z7's go-there branch)"
    [ "${L%% *}" = "$WS_C" ] \
        || bad "LAUNCH lap$lap -- the new window landed on '${L%% *}', not the desktop the click was made on ($WS_C)"
    [ "$A3" = "$A0" ] || bad "LAUNCH lap$lap -- the window on desktop $WS_A moved: '$A0' -> '$A3'"
    [ "$B3" = "$B0" ] || bad "LAUNCH lap$lap -- the window on desktop $WS_B moved: '$B0' -> '$B3'"

    dsp "hl.dsp.focus({workspace = $WS_A})"; sleep 0.5
done

say
[ $FAIL -eq 0 ] && say "v6_dock_ws_scope PASS -- the click counts, and acts on, this desktop only"
exit $FAIL
