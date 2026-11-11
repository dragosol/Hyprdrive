#!/usr/bin/env bash
# fs_close_home -- a fullscreen app closed on the desktop it was given: its desktop goes and the view returns to where it came from.
# Protects (owner, 2026-11-11): "once I've closed an app that was sent to another
# desktop to fullscreen, it should remove that desktop and return me to its
# origin desktop"; designed behaviours, Fullscreen [11-05..11-09] ("exit puts
# everything back and removes the desktop it made").
# Asserts, from 1:{a,b} 2:{c} 3:{d} unless said (a fullscreen -> alone on 2):
#   A. a closed (asked to close) while its desktop is shown: 1 is shown within
#      2.5 s, the ids are the start's again (its place given back: c, d back on 2, 3)
#   B. a KILLED (SIGKILL, no goodbye): the same
#   C. a closed while the user looks at c's desktop: the view stays there, ids back
#   D. a window opened over a (it goes beside, to 3) is still open when a closes:
#      1 shown, a's desktop gone, the beside window keeps a desktop of its own;
#      it closes too -> the start's ids
#   E. the home emptied during the trip (b closed, so desktop 1 went): a closed ->
#      the view goes to the populated desktop nearest home's place, no empty
#      desktop is left, ids unique
#   F. an X11 "game" (wine_state.exe, fullscreen) that unmaps and maps again
#      within 0.6 s: the trip goes on (still fullscreen on its own desktop); when
#      it exits: home shown, ids back
#   G. the dock's "Always Open in" Empty Workspace + Fullscreen chips on (kitty):
#      launched from 1 it opens alone on an empty desktop, fullscreen; closed ->
#      1 is shown and that desktop is gone
# Control: --control-so a build before the fix (fa18ef6): E (the view stays on the
# emptied desktop, home gone), G (the view stays on the emptied desktop the chips
# opened it on) and F (the 0.6 s unmap is taken for a close) fail. Recorded
# 2026-11-11. A..D pass on fa18ef6 too: they pin the behaviour that worked.
source "$(dirname "$0")/lib.sh"
gate_begin fch
control_build "fa18ef6 (the build before this fix)"
setup() { rig_start "$@"; trace_on; go 1; kw a; kw b; go 2; kw c; go 3; kw d; go 1; sleep 0.5; A=$(addr_of a); START=$(ids); }
fs_a() { focus "$A"; fs "$A" set; wait_for 3 "[ \"\$(win a .workspace.id)\" = 2 ]"; sleep 1; }
GONE='1:1 2:1 3:1'  # the start without a
back() { wait_for "${2:-3}" "[ \"\$(ids)\" = '$1' ]"; }

setup
fs_a; close_win "$A"; T0=$(date +%s%N); back "$GONE" 3; MS=$(( ($(date +%s%N) - T0) / 1000000 ))
check "A: closed on its desktop: home (1) shown" "$(is "$(shown)" 1)" "shown $(shown)"
check "A: ... and its desktop given back within 2.5 s" "$(is "$(ids)" "$GONE")$( [ $MS -le 2500 ] || echo ' late')" "$(ids) after ${MS} ms"
rig_stop

setup
fs_a; SU kill -9 "$(win a .pid)"; back "$GONE" 3
check "B: killed on its desktop: home shown, ids back" "$(is "$(shown) $(ids)" "1 $GONE")" "shown $(shown), $(ids)"
rig_stop

setup
fs_a; go "$(win c .workspace.id)"; sleep 0.8; close_win "$A"; back "$GONE" 3; sleep 0.3
check "C: closed off screen: the view stays on c's desktop, ids back" "$(is "$(shown) $(ids)" "$(win c .workspace.id) $GONE")" "shown $(shown), c on $(win c .workspace.id), $(ids)"
rig_stop

setup
fs_a; kw x; sleep 1
check "D: a window opened over a goes beside it (3)" "$(is "$(win x .workspace.id)" 3)" "x on $(win x .workspace.id), $(ids)"
go 2; sleep 0.8; close_win "$A"; sleep 2.5; settle 3 ids
check "D: a closed: 1 shown, its desktop gone, x on a desktop of its own" "$(is "$(shown) $(ids)" "1 1:1 2:1 3:1 4:1")" "shown $(shown), x on $(win x .workspace.id), $(ids)"
close_win "$(addr_of x)"; back "$GONE" 3
check "D: x closed too: the start's ids (without a)" "$(is "$(ids)" "$GONE")" "$(ids)"
rig_stop

setup
fs_a; close_win "$(addr_of b)"; sleep 0.8; close_win "$A"; sleep 2.5; settle 3 ids
EMPTY=$(J workspaces | jq '[.[] | select(.id > 0 and .windows == 0)] | length')
check "E: home emptied meanwhile: the view goes to the nearest populated desktop (c's)" "$(is "$(shown)" "$(win c .workspace.id)")" "shown $(shown), c on $(win c .workspace.id), $(ids)"
check "E: ... no empty desktop left, ids unique" "$(is "$EMPTY$(uniq_ok && echo u)" 0u)" "$(ids)"
rig_stop

# F: an X11 game that unmaps and maps again
xdisplay() { hlog 4000 | grep -o 'DISPLAY: :[0-9]*' | tail -1 | grep -o ':[0-9]*$'; }
cc -O2 -o "$GOUT/wine_state" "$ROOT/tests/rig/xstate/wine_state.c" $(pkg-config --cflags --libs xcb) 2>/dev/null && chmod 755 "$GOUT" "$GOUT/wine_state"
if [ -x "$GOUT/wine_state" ]; then
    setup
    wait_for 6 '[ -n "$(xdisplay)" ]' || { $R win env DISPLAY=:99 true >/dev/null 2>&1; wait_for 6 '[ -n "$(xdisplay)" ]'; }
    D=$(xdisplay)
    $R win env DISPLAY="$D" WINE_STATE_REMAP=3 "$GOUT/wine_state" fs 7 >/dev/null
    wait_for 5 "[ \"\$(win wine_state.exe .fullscreen)\" = 2 ]"; sleep 1.5
    WS=$(win wine_state.exe .workspace.id); S1=$(ids)
    check "F: the game went fullscreen onto a desktop of its own" "$(is "$(win wine_state.exe .fullscreen) $(shown)" "2 $WS")" "$(geom), shown $(shown)"
    sleep 2.5  # the unmap at 3 s and the map at 3.6 s
    check "F: unmapped and mapped again within 0.6 s: still fullscreen there, still shown" "$(is "$(win wine_state.exe '"\(.fullscreen) \(.workspace.id)"') $(shown) $(ids)" "\"2 $WS\" $WS $S1")" "$(win wine_state.exe '"\(.fullscreen) \(.workspace.id)"'), shown $(shown), $(ids) (was $S1)"
    back "$START" 6; sleep 0.3
    check "F: the game exits: home shown, ids back" "$(is "$(shown) $(ids)" "1 $START")" "shown $(shown), $(ids)"
    rig_stop
else
    subskip "F: the X11 game" "cannot build wine_state (xcb headers?)"
fi

# G: both "Always Open in" chips on kitty
setup --env "XDG_STATE_HOME=/tmp/hl-$HL_NAME/state"
SU mkdir -p "/tmp/hl-$HL_NAME/state/hyprdrive"
for f in fullscreen-apps empty-desktop-apps; do SU sh -c "echo kitty > /tmp/hl-$HL_NAME/state/hyprdrive/$f"; done
ev 'hl.dispatch(hl.dsp.exec_cmd("kitty -o remember_window_size=no -o initial_window_width=900 -o initial_window_height=600"))'
wait_for 6 "[ \"\$(win kitty .fullscreen)\" = 2 ]"; sleep 1.2
KD=$(win kitty .workspace.id)
check "G: both chips: kitty alone on an empty desktop, fullscreen, shown" "$(is "$(win kitty .fullscreen) $(shown) $(J clients | jq "[.[] | select(.workspace.id == $KD)] | length")" "2 $KD 1")" "$(geom), shown $(shown)"
close_win "$(addr_of kitty)"; back "$START" 3; sleep 0.3
check "G: closed there: back to 1, its desktop gone" "$(is "$(shown) $(ids)" "1 $START")" "shown $(shown), $(ids)"
gate_end
