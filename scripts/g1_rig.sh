#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC 13.11 G1 -- TYPE-TO-SEARCH FROM ANYWHERE. Runs IN THE GUEST.
#
# G1's only measurable divergence from the GNOME reference (1.1, "What counts as
# a type to search trigger") is WHITESPACE: GNOME rejects a keysym that is pure
# whitespace, so SPACE on an empty query must be a no-op. Ours started a search
# with a leading space.
#
# The claim is "a keystroke changed NOTHING", so the rig is built entirely out
# of frame diffs and every no-op claim is bracketed by a control that MUST move:
#
#   00-ctrlA  overview open, no query
#   10-space  after SPACE            -- must equal ctrlA
#   01-ctrlB  after the same wait    -- must equal ctrlA  (no drift)
#   20-typed  after 'k'              -- MUST DIFFER       (pipeline is live)
#   30-kx     query "kx"
#   40-k_x    query "k x"            -- MUST DIFFER from 30 (space DID type)
#
# A frozen output hands back the same frame forever, so 20 and 40 are what stop
# this rig passing on a dead compositor.
set -u
source "$(dirname "$0")/lib/rig.sh"   # env discovery, ov/dsp/key, K_* keycodes
rig_env || exit 1
OUT=/mnt/host/g1; mkdir -p $OUT

case "${1:?usage: g1_rig.sh fixture|run <tag>}" in

fixture)
    systemctl --user stop hyprwall.timer 2>/dev/null
    ov off; sleep 1
    pkill -x kitty 2>/dev/null; sleep 1.5

    # Exactly one headless output with Virtual-1 off: a starved Virtual-1 stalls
    # every output including headless (X1 fixture established this).
    hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = false})" >/dev/null 2>&1; sleep 1.2
    for m in $(hyprctl monitors all -j | python3 -c "
import json,sys
print(' '.join(m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')))"); do
        hyprctl output remove "$m" >/dev/null 2>&1; sleep 0.4
    done
    sleep 1
    hyprctl output create headless >/dev/null 2>&1; sleep 1.5
    MON=$(hyprctl monitors -j | python3 -c "
import json,sys
hs=[m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')]
print(hs[0] if len(hs)==1 else '')")
    [ -n "$MON" ] || { echo "ABORT: expected exactly one headless output"; exit 1; }
    # SET THE MODE: `output create headless` defaults to 1920x1080 and every
    # geometry this suite predicts is a function of the guest's 2560x1600.
    # headless_on does this; this block hand-rolls the output because
    # headless_on installs an EXIT trap that would tear it down when the
    # fixture script exits -- so it must hand-roll the mode too.
    #
    # Virtual-1 goes DOWN FIRST: two enabled outputs at 0x0 overlap, and the
    # "Monitor HEADLESS-N overlaps" notification Hyprland then raises sits in
    # the frame for the next ~15 seconds and moves under every diff below.
    hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = true})" >/dev/null 2>&1; sleep 1.5
    hyprctl eval "return hl.monitor({output = [[$MON]], mode = [[$RIG_HEADLESS_MODE]], position = [[0x0]], scale = 1})" >/dev/null 2>&1; sleep 1.5
    read -r GOT_W GOT_H <<< "$(hyprctl monitors -j | python3 -c "
import json,sys
m=json.load(sys.stdin)[0]; print(m['width'], m['height'])")"
    WANT_W=${RIG_HEADLESS_MODE%%x*}; WANT_REST=${RIG_HEADLESS_MODE#*x}; WANT_H=${WANT_REST%%@*}
    [ "$GOT_W" = "$WANT_W" ] && [ "$GOT_H" = "$WANT_H" ] \
        || { echo "ABORT: headless came up ${GOT_W}x${GOT_H}, not ${WANT_W}x${WANT_H}"; exit 1; }
    printf '%s\n' "$MON" > $OUT/mon

    # kitty, never foot (standing rule): foot has no per-window opaque switch and
    # a translucent fixture makes every pixel count ambiguous.
    spawn() { # class colour ws
        dsp "hl.dsp.focus({monitor = \"$MON\"})"; sleep 0.15
        dsp "hl.dsp.focus({workspace = $3})"; sleep 0.2
        setsid kitty -c NONE --class "$1" -o background="$2" -o background_opacity=1.0 \
            -o confirm_os_window_close=0 --hold sh -c 'clear' >/dev/null 2>&1 </dev/null &
        sleep 2.2
        hyprctl clients -j | grep -q "\"$1\"" || { echo "ABORT: $1 did not appear"; exit 1; }
    }
    spawn G1AAA '#ff0000' 1
    spawn G1BBB '#0000ff' 1
    spawn G1CCC '#00ff00' 2
    dsp 'hl.dsp.focus({workspace = 1})'; sleep 1.0

    hyprctl clients -j > $OUT/fixture-clients.json
    echo "output: $MON"
    echo G1_FIXTURE_OK
    ;;

run)
    TAG=${2:?usage: g1_rig.sh run <tag>}
    MON=$(cat $OUT/mon)
    shot() { grim -o "$MON" "$OUT/$TAG-$1.png"; }

    ov off; sleep 1.0
    ov on;  sleep 2.5

    # The grader masks the chrome that ticks, and it finds the layer-shell half
    # of it here rather than from memory: the quickshell bar's clock and CPU
    # readouts are a layer surface on this output, so `layers` names and places
    # them. Dumped WITH THE OVERVIEW UP, which is the state every frame below
    # is taken in.
    hyprctl layers -j > $OUT/layers.json

    # The drift control is taken BEFORE the space, not after: the space's effect
    # (if any) persists in the query, so a later "idle" frame would inherit it
    # and the control would restate the measurement instead of bracketing it.
    shot 00-ctrlA;  sleep 1.2; shot 01-ctrlB
    key $K_SPACE;   sleep 1.2; shot 10-space
    key $K_K;       sleep 1.5; shot 20-typed

    key $K_ESC;     sleep 1.2                    # clear the query, overview stays
    key $K_K; key $K_X;        sleep 1.5; shot 30-kx
    key $K_ESC;     sleep 1.2
    key $K_K; key $K_SPACE; key $K_X; sleep 1.5; shot 40-k_x
    key $K_ESC;     sleep 1.0

    # G1's negative half: TAB, BACKSPACE and an F-key must not start a search.
    # ARROWS are deliberately absent -- they legitimately move the tile
    # selection, so a frame diff cannot tell "a search started" from "the
    # selection moved" and the phase would be measuring the wrong claim.
    key $K_TAB; key $K_BKSP; key $K_F5; sleep 1.5; shot 50-nostart

    # Close before handing back. This rig used to end with the overview still
    # up on the headless output, and the gate's EXIT trap then removed that
    # output from under it -- which leaves the overview holding a dead monitor
    # and makes the NEXT gate's first `ov off` segfault the compositor
    # (scrollOverview.cpp:5052; see ov_off_settled in lib/rig.sh). headless_off
    # now closes too, so this is belt and braces, but a rig that opens the
    # overview should close it.
    ov_off_settled

    ls -la $OUT/$TAG-*.png
    echo G1_RUN_OK
    ;;
esac
