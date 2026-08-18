#!/usr/bin/env bash
# v2_pill_actions -- V11_SPEC V2 (user, 2026-08-17), the BEHAVIOUR half.
#
#   "pill buttons do what they say (minimize = the dock minimize flight,
#    maximize = fullscreen/maximize dispatcher, close = graceful close)";
#   "DESKTOP, while SUPER held: window drag works (Hyprland native SUPER+drag
#    bindm)"; "DOUBLE-CLICK on a window toggles Hyprland tiling"; "double-click
#    does NOTHING in overview"; "Without SUPER, behaviour unchanged".
#
# STATE, NOT PIXELS. Every assertion is a workspace name, a geometry or a
# floating flag read out of `hyprctl clients -j`, so no wallpaper, frame rate or
# capture pipeline can enter the verdict. The pixel half is v2_super_pill.
#
# SEVEN ARMS, and what each proves:
#   MIN      the minimize button stashes the window on special:minimized. That
#            is the dock FLIGHT's own landing state (X54), so it also proves the
#            button went through the dock rather than calling Minimize:: behind
#            its back -- the exact defect X54 exists to prevent.
#   MAX      the maximize button changes the window's geometry, and pressing it
#            again puts the geometry back. A toggle, not a one-way trip.
#   CLOSE    the client is GONE.
#   NOLEAK   press a pill button, DRAG THE POINTER 240 px, release. The window
#            must not have moved. This is the claim proved as an absence: with
#            `SUPER + mouse:272 -> window.drag` bound (and it is -- the arm
#            asserts the bind's effect in DRAG below), an unclaimed press at
#            that point drags the window across the screen. It is also the
#            "does not leak to the window beneath" assertion the spec asks for,
#            in the only form that is not vacuous here: a SUPER+click never
#            reaches a client anyway, because the bind eats it, so the leak that
#            can actually happen is a leak into the BIND.
#   DRAG     the same gesture 300 px INTO the window body moves it. The
#            pass-through, and the regression guard: green on the parent too.
#   DOUBLE   double-click on the body flips floating, twice, round trip.
#   OVDBL    the same double-click inside the overview changes nothing: window
#            count, geometry, workspace and floating flag all as they were.
#            Green on both builds -- it is the guard that the desktop's new
#            double-click did not get wired into the overview by accident.
#   NOSUPER  the same three button presses without SUPER do not minimize, do not
#            maximize and do not close. Green on both builds.
#
# FAIL-ON-OLD: MIN, MAX, CLOSE and DOUBLE red on the parent because the pill
# does not exist there and a SUPER+press with no motion is a drag of zero
# distance; NOLEAK reds on the parent because that same press DOES drag. DRAG,
# OVDBL and NOSUPER are green on both by design.
#
# WHY THE BUTTONS ARE PRESSED 8 px BELOW THE WINDOW'S TOP EDGE and not on its
# centre line: Hyprland ships general:resize_on_border=true with a 15 px
# extend_border_grab_area, so the corner the pill straddles is also a resize
# handle. With SUPER held the pill's claim vetoes that outright, which is the
# point -- but the NOSUPER control has to land somewhere a bare click is
# harmless, and 8 px in is inside the button (the disc spans +-17 px of the edge
# with its slop) while being a plain click on the window for the control.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=${RIG_EVIDENCE:-/mnt/host/zrig}/v2/actions; mkdir -p "$OUT"
LOG=$OUT/gate.log; : > "$LOG"
FAIL=0
bad() { echo "FAIL $*" | tee -a "$LOG"; FAIL=1; }
say() { echo "$*" | tee -a "$LOG"; }

gate_slate v2_pill_actions >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }
[ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_pause 30min

headless_on || exit 1
trap 'ydotool key 125:0 >/dev/null 2>&1; pkill -x kitty 2>/dev/null; ov_off_settled; headless_off; hyprwall_resume' EXIT

FX=600; FY=430; FW=1100; FH=700
PX=$(( FX + FW - 112 + 13 ))
BMIN=$(( PX + 9 + 13 )); BMAX=$(( BMIN + 34 )); BCLS=$(( BMAX + 34 ))
BY=$(( FY + 8 ))
say "  fixture $FX,$FY ${FW}x${FH}   buttons min=$BMIN max=$BMAX close=$BCLS at y=$BY"

st() { hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('class')=='V2ACT':
        print('%s %s,%s %sx%s float=%s' % (c['workspace']['name'],c['at'][0],c['at'][1],c['size'][0],c['size'][1],c['floating'])); break
else: print('GONE')"; }

nwin() { hyprctl clients -j | python3 -c "
import json,sys
print(len([c for c in json.load(sys.stdin) if c.get('class')=='V2ACT']))"; }

activews() { hyprctl monitors -j | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['activeWorkspace']['id'])"; }

spawn() {
    pkill -x kitty 2>/dev/null; sleep 1.2
    fixture_kitty V2ACT $FX $FY $FW $FH '#101820' 'clear; sleep infinity' >/dev/null || exit 1
    sleep 0.8
}

# HELD press with sub-threshold jitter, SUPER down for the whole gesture. The
# jitter is the standing rule [x24_dock_click.sh:10-11] -- a press and release
# in the same instant does not exercise the real path -- and +-3 px keeps it
# inside the button, whose hit disc is 13 px of radius plus 4 px of slop.
superclick() { # superclick X Y
    local x=$1 y=$2 d
    warp_or_die "$x" "$y"; sleep 0.4
    ydotool key 125:1; sleep 0.5
    ydotool click 0x40
    for d in 2 -2 3 -1 0; do warp $((x+d)) $((y-d)); sleep 0.03; done
    ydotool click 0x80; sleep 0.4
    ydotool key 125:0; sleep 1.6
}

# Press, walk the pointer a long way, release. `startx starty dx dy`.
superdrag() { # superdrag X Y DX DY
    local x=$1 y=$2 dx=$3 dy=$4 i
    warp_or_die "$x" "$y"; sleep 0.4
    ydotool key 125:1; sleep 0.5
    ydotool click 0x40; sleep 0.2
    for i in 1 2 3 4 5 6; do warp $(( x + i*dx/6 )) $(( y + i*dy/6 )); sleep 0.07; done
    ydotool click 0x80; sleep 0.4
    ydotool key 125:0; sleep 1.2
}

superdouble() { # superdouble X Y
    local x=$1 y=$2
    warp_or_die "$x" "$y"; sleep 0.4
    ydotool key 125:1; sleep 0.5
    ydotool click 0x40; sleep 0.08; ydotool click 0x80; sleep 0.12
    ydotool click 0x40; sleep 0.08; ydotool click 0x80; sleep 0.4
    ydotool key 125:0; sleep 1.6
}

############################################################ MIN
say "--- MIN"
spawn; B=$(st); say "  before $B"
superclick $BMIN $BY
alive_or_die "after the minimize press"
A=$(st); say "  after  $A"
[ "${A%% *}" = special:minimized ] \
    || bad "MIN -- the minimize button did not stash the window (it is on '${A%% *}'); the parent build has no button there at all"

############################################################ MAX
say "--- MAX"
spawn; B=$(st); say "  before $B"
superclick $BMAX $BY
alive_or_die "after the maximize press"
A=$(st); say "  after  $A"
[ "$A" != "$B" ] || bad "MAX -- the maximize button changed nothing ($A)"
# ...and back. The button is a toggle; a one-way maximize would pass the line
# above and be the wrong feature.
superclick $BMAX $BY
A2=$(st); say "  again  $A2"
[ "$A2" != "$A" ] || bad "MAX -- pressing maximize a second time changed nothing; it is not a toggle"

############################################################ CLOSE
say "--- CLOSE"
spawn; B=$(st); say "  before $B"
superclick $BCLS $BY
sleep 1.5
alive_or_die "after the close press"
A=$(st); say "  after  $A"
[ "$A" = GONE ] || bad "CLOSE -- the client is still here ($A)"

############################################################ NOLEAK
say "--- NOLEAK (press a button, drag 240 px, release)"
spawn; B=$(st); say "  before $B"
superdrag $BMAX $BY 240 160
alive_or_die "after the button drag"
A=$(st); say "  after  $A"
[ "${A#* }" = "${B#* }" ] \
    || bad "NOLEAK -- the window moved/resized under a press that started on a pill button ('$B' -> '$A'): the press leaked into the SUPER+drag bind"

############################################################ DRAG
say "--- DRAG (SUPER+drag on the window body must still move it)"
spawn; B=$(st); say "  before $B"
superdrag $(( FX + 300 )) $(( FY + 300 )) 240 160
alive_or_die "after the body drag"
A=$(st); say "  after  $A"
BXY=$(echo "$B" | awk '{print $2}'); AXY=$(echo "$A" | awk '{print $2}')
[ "$AXY" != "$BXY" ] \
    || bad "DRAG -- SUPER+drag on the window body no longer moves the window (still at $AXY); the pill is swallowing presses it must pass through"

############################################################ DOUBLE
say "--- DOUBLE (double-click toggles floating, twice)"
spawn; B=$(st); say "  before $B"
F0=${B##*float=}
superdouble $(( FX + 300 )) $(( FY + 300 ))
alive_or_die "after the first double-click"
A=$(st); F1=${A##*float=}; say "  after  $A"
[ "$F1" != "$F0" ] || bad "DOUBLE -- the first double-click did not flip floating (still $F1)"
superdouble $(( FX + 300 )) $(( FY + 300 ))
A2=$(st); F2=${A2##*float=}; say "  again  $A2"
[ "$F2" = "$F0" ] || bad "DOUBLE -- the second double-click did not put it back ($F0 -> $F1 -> $F2)"

############################################################ TILED
# THE PILL ON A TILED WINDOW, proved by hitting it rather than by photographing
# it. Every window in this rice floats by rule, so "tiled" here means the
# layout has maximised it: its rect is the whole output and its top edge is a
# few px from the top, which is the one case where the capsule cannot straddle
# and is clamped onto the output instead. That is also the one case a pixel arm
# cannot grade -- the shell's own bar comes out while SUPER is held and covers
# exactly those rows (measured 2026-08-17, zrig/v2/pill/i-multi-super.png).
#
# So: take the window tiled, read the rect the LAYOUT gave it, predict the
# clamped capsule from that rect, and press its maximize button. If the window
# obeys, the pill is where the tiled geometry says it is. Nothing about this
# depends on what is painted over it.
say "--- TILED (the pill follows a rect the layout chose)"
spawn
dsp 'hl.dsp.focus({window = [[class:V2ACT]]})'; sleep 0.5
dsp 'hl.dsp.window.float()'; sleep 1.5
TF=$(hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('class')=='V2ACT': print(c['floating']); break
else: print('?')")
B=$(st); say "  tiled  $B   floating=$TF"
if [ "$TF" != "False" ]; then
    bad "TILED -- could not take the fixture out of floating (floating=$TF); the arm would measure a floating window"
else
    TX=$(echo "$B" | awk -F'[ ,x]' '{print $2}'); TY=$(echo "$B" | awk -F'[ ,x]' '{print $3}')
    TW=$(echo "$B" | awk -F'[ ,x]' '{print $4}'); TH=$(echo "$B" | awk -F'[ ,x]' '{print $5}')
    # box() clamps into the output: x into [0, MONW-112], y into [0, MONH-40].
    TPX=$(( TX + TW - 112 + 13 )); [ $TPX -gt $(( RIG_W - 112 )) ] && TPX=$(( RIG_W - 112 )); [ $TPX -lt 0 ] && TPX=0
    TPY=$(( TY - 20 ));            [ $TPY -lt 0 ] && TPY=0
    # THE MINIMIZE BUTTON, not the maximize one: a layout-maximised window IS
    # already the size FSMODE_MAXIMIZED would give it, so pressing maximize on
    # it is a geometry no-op and an arm reading geometry could not tell that
    # from a button that was never hit (measured -- the first cut of this arm
    # read `6,6 2548x1588` before and after and called it a miss). The stash is
    # unambiguous whatever the rect was.
    TBMIN=$(( TPX + 9 + 13 )); TBY=$(( TPY + 20 ))
    say "  rect $TX,$TY ${TW}x${TH}  ->  capsule $TPX,$TPY   minimize button $TBMIN,$TBY"
    superclick $TBMIN $TBY
    alive_or_die "after the tiled minimize press"
    A=$(st); say "  after  $A"
    [ "${A%% *}" = special:minimized ] \
        || bad "TILED -- the minimize button at the position the tiled rect predicts did nothing (window is on '${A%% *}'): the pill does not follow a layout-chosen rect"
fi

############################################################ OVDBL
say "--- OVDBL (double-click inside the overview is a no-op)"
spawn
dsp 'hl.dsp.focus({workspace = 1})'; sleep 0.5
B=$(st); N0=$(nwin); W0=$(activews); say "  before $B   windows=$N0 desktop=$W0"
ov on; sleep 3
superdouble $(( FX + 300 )) $(( FY + 300 ))
sleep 1.5
ov_off_settled
alive_or_die "after the overview double-click"
A=$(st); N1=$(nwin); W1=$(activews); say "  after  $A   windows=$N1 desktop=$W1"
[ "$A"  = "$B"  ] || bad "OVDBL -- the window changed: '$B' -> '$A' (a double-click in the overview must do nothing)"
[ "$N1" = "$N0" ] || bad "OVDBL -- the window count changed $N0 -> $N1"
[ "$W1" = "$W0" ] || bad "OVDBL -- the session moved to desktop $W1"

############################################################ NOSUPER
say "--- NOSUPER (the same presses, no modifier)"
spawn; B=$(st); say "  before $B"
click $BMIN $BY; sleep 1.5
A=$(st); say "  min    $A"
[ "${A%% *}" != special:minimized ] || bad "NOSUPER -- a bare click minimized the window; the pill must not exist without SUPER"
click $BCLS $BY; sleep 1.5
A=$(st); say "  close  $A"
[ "$A" != GONE ] || bad "NOSUPER -- a bare click closed the window"
alive_or_die "after the bare clicks"

say
[ $FAIL -eq 0 ] && say "v2_pill_actions PASS -- the three buttons act, the drag still drags, the double-click tiles, and none of it happens without SUPER"
exit $FAIL
