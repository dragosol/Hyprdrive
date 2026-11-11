#!/usr/bin/env bash
# fs_move_close -- a fullscreen window moved onto a populated desktop exits fullscreen and stays; the app closed off screen pays its debt.
# Protects (designed behaviours, Fullscreen [11-05..11-09]): "a fullscreen
# window moved onto a populated desktop exits fullscreen and stays there", and
# "exit ... removes the desktop it made" when the exit is a CLOSE while the
# trip's desktop is off screen (the old "-1" debt; tests/rig/fsdesk/README.md case 5).
# Asserts, from 1:{a,b} 2:{c} 3:{d}:
#   A. a fullscreen (alone on 2, c/d on 3/4), moved to 3 (c's desktop): a stays with
#      c, NOT fullscreen, after 2 s; the trip's desktop is given back (c's becomes 2)
#   B. fresh start; a fullscreen (on 2), look back at 1, close a: 1:1 2:1 3:1
#      (desktop 2 paid back), the trace never says "place -1" or "a debt with no
#      place", no desktop shares a number at any sample
#   C..G. (owner, 2026-11-11) a fullscreen window moved onto a populated desktop
#      leaves fullscreen and stays there: C a trip's window by the dock menu's
#      "Move to this workspace" (`debug movehere`), D a settled one (alone on its
#      desktop) by the dispatcher, E Mosaic: a settled one by the dock menu, at
#      its own size, the target's windows not resized, G a fullscreen game
#      (wine_state.exe) -- still out 2.5 s later; F moved onto an EMPTY desktop
#      it stays fullscreen
# Control: --so the pre-fix build 8bb258c (scratchpad p3t/old.so): case B prints
# "paying back place -1" (fsdesk README; recorded 2026-11-11: the gate FAILS on it).
#   H..L. (owner, 2026-11-11: "yes") a MAXIMIZED window too: H by the dock menu, I
#      by the dispatcher onto a populated desktop: not maximized; J onto an EMPTY
#      one: still maximized; K Mosaic: at its own size, the others not resized;
#      L an X11 client that maximizes itself (wine_state max): out, and still out
#      2.5 s later (its re-assert is caught and held out: SUPPRESS_MAXIMIZE)
# C..G: --control-so fa18ef6 (before the move fix): D, E and G stay fullscreen
# (C passes there: a trip's move was handled). Recorded 2026-11-11.
#   P..T. (owner, 2026-11-11: "if I move a window into a desktop with a fullscreen
#      app it should un-fullscreen the app in the target desktop") an ORDINARY
#      window moved onto a desktop with P a settled fullscreen app (dock menu),
#      Q a trip's fullscreen app (dispatcher: the trip ends there, nothing flies
#      home, nothing paid back: b on 1, a and c on the trip's desktop), R a maximized app (dispatcher), S a
#      fullscreen game (dock menu), T Mosaic (dock menu: the app back at its own
#      size, the arriving one at its, the other not resized): the app is out,
#      both on that desktop, still so 3 s later. (Overview drag: not driven.)
# H..L: --control-so <a4d6892 build>: H, I, K and L stay maximized; J passes.
# P..T: the same control: the app stays fullscreen (Q: a trip; S: the game may go to the dock).
source "$(dirname "$0")/lib.sh"
gate_begin fsm
control_build "8bb258c, e.g. the scratchpad p3t/old.so"
setup() { rig_start; trace_on; go 1; kw a; kw b; go 2; kw c; go 3; kw d; go 1; sleep 0.5; A=$(addr_of a); START=$(ids); }

setup
focus "$A"; fs "$A" set; sleep 1.2
check "A: a went fullscreen alone on 2" "$(is "$(win a '"\(.workspace.id) \(.fullscreen)"')" '"2 2"')" "$(win a '"\(.workspace.id) \(.fullscreen)"')"
CW=$(win c .workspace.id); move_to "$A" "$CW"; sleep 2; settle 3 ids
# (the trip's place 2 is paid back, so c's desktop is renumbered 3 -> 2: compare desktops, not numbers)
check "A: moved onto c's desktop it stays there, with c" "$(is "$(win a .workspace.id)" "$(win c .workspace.id)")" "a on $(win a .workspace.id), c on $(win c .workspace.id), $(ids)"
check "A: and the trip's desktop is gone: 1:{b} 2:{c,a} 3:{d}" "$(is "$(ids)" '1:1 2:2 3:1')" "$(ids)"
check "A: and is no longer fullscreen" "$(is "$(win a .fullscreen)" 0)" "fullscreen=$(win a .fullscreen)"
check "A: desktop numbers unique" "$(uniq_ok && echo 1)" "$(ids)"
rig_stop

setup
sampler_start ids sample_ids
focus "$A"; fs "$A" set; sleep 1.2; go 1; sleep 1
close_win "$A"; wait_for 6 "[ \"\$(ids)\" = '1:1 2:1 3:1' ]"; sleep 0.5
n=$(sampler_stop ids)
check "B: closed off screen: its desktop paid back" "$(is "$(ids)" '1:1 2:1 3:1')" "$(ids)"
bad=$(trace | grep -c 'place -1\|debt with no place')
check "B: never a debt at place -1" "$(is "$bad" 0)" "$(trace | grep -m1 'place -1\|no place' | cut -d' ' -f3-)"
check "B: ids unique at all $n samples" "$(is "$(grep -c DUP "$GOUT/ids.samp")" 0)" "$(grep -m1 DUP "$GOUT/ids.samp")"
rig_stop

# MOVED ONTO A POPULATED DESKTOP, A FULLSCREEN WINDOW LEAVES FULLSCREEN, however
# it got there (owner, 2026-11-11: "if I move a fullscreen window 'to this
# workspace' and there's other apps on that workspace it should un-fullscreen it";
# "Fullscreen game moved to a populated desktop yes should also leave fullscreen")
setup
focus "$A"; fs "$A" set; sleep 1.2; go "$(win c .workspace.id)"; sleep 0.8
dbg movehere a >/dev/null; sleep 1.5; settle 3 ids
check "C: a trip's window, dock menu 'Move to this workspace' onto c's desktop: there, not fullscreen" "$(is "$(win a '"\(.workspace.id) \(.fullscreen)"')" "\"$(win c .workspace.id) 0\"")" "$(win a '"\(.workspace.id) \(.fullscreen)"'), c on $(win c .workspace.id)"
check "C: ... its trip's desktop given back: 1:{b} 2:{c,a} 3:{d}" "$(is "$(ids)" '1:1 2:2 3:1')" "$(ids)"
D=$(addr_of d); go 3; sleep 0.5; focus "$D"; fs "$D" set; sleep 1.2
check "D: d alone on 3 goes fullscreen there (settled)" "$(is "$(win d '"\(.workspace.id) \(.fullscreen)"')" '"3 2"')" "$(win d '"\(.workspace.id) \(.fullscreen)"')"
move_to "$D" 1; sleep 1.5; settle 3 ids
check "D: settled, moved by the dispatcher onto 1: not fullscreen, on 1, 3 gone" "$(is "$(win d '"\(.workspace.id) \(.fullscreen)"') $(ids)" '"1 0" 1:2 2:2')" "$(win d '"\(.workspace.id) \(.fullscreen)"') $(ids)"
B=$(addr_of b); move_to "$B" 4; sleep 0.8; go 4; focus "$B"; fs "$B" set; sleep 1.2; move_to "$B" 7; sleep 1.5
check "F: settled, moved onto an EMPTY desktop: still fullscreen, alone there" "$(is "$(win b '"\(.workspace.id) \(.fullscreen)"')" '"7 2"')" "$(win b '"\(.workspace.id) \(.fullscreen)"') $(ids)"
rig_stop

# A MAXIMIZED window moved onto a populated desktop is un-maximized; onto an empty
# one it stays maximized (owner, 2026-11-11: "yes")
mx() { ev "hl.dispatch(hl.dsp.window.fullscreen({ window = [[address:$1]], mode = \"maximized\", action = \"$2\" }))"; }
setup
D=$(addr_of d); go "$(win d .workspace.id)"; sleep 0.4; focus "$D"; mx "$D" set; sleep 1
check "H: d maximized, alone on its desktop" "$(is "$(win d .fullscreen)" 1)" "$(win d '"\(.workspace.id) \(.fullscreen)"')"
go 1; sleep 0.6; dbg movehere d >/dev/null; sleep 1.5; settle 3 geom
check "H: moved onto 1 (a, b there) by the dock menu: on 1, not maximized" "$(is "$(win d '"\(.workspace.id) \(.fullscreen)"')" '"1 0"')" "$(geom)"
C=$(addr_of c); CW=$(win c .workspace.id); go "$CW"; sleep 0.4; focus "$C"; mx "$C" set; sleep 1
move_to "$C" 1; sleep 1.5; settle 3 geom
check "I: c maximized alone on $CW, moved onto 1 by the dispatcher: on 1, not maximized" "$(is "$(win c '"\(.workspace.id) \(.fullscreen)"')" '"1 0"')" "$(geom)"
B=$(addr_of b); focus "$B"; mx "$B" set; sleep 1; move_to "$B" 7; sleep 1.5
check "J: b maximized, moved onto an EMPTY desktop: still maximized there" "$(is "$(win b '"\(.workspace.id) \(.fullscreen)"')" '"7 1"')" "$(win b '"\(.workspace.id) \(.fullscreen)"') $(ids)"
rig_stop

# AN ORDINARY WINDOW MOVED ONTO A FULLSCREEN (MAXIMIZED) APP'S DESKTOP TAKES THE
# APP OUT (owner, 2026-11-11: "if I move a window into a desktop with a fullscreen
# app it should un-fullscreen the app in the target desktop"); still out 3 s later
fsw() { win "$1" '"\(.workspace.id) \(.fullscreen)"'; }
setup
D=$(addr_of d); go 3; sleep 0.4; focus "$D"; fs "$D" set; sleep 1.2
check "P: d fullscreen alone on 3 (settled)" "$(is "$(fsw d)" '"3 2"')" "$(fsw d)"
dbg movehere b >/dev/null; sleep 1; P1="$(fsw d) $(fsw b)"; sleep 3; settle 3 geom
check "P: b moved onto 3 by the dock menu: d out of fullscreen, both on 3, still so 3 s later" "$(is "$P1 $(fsw d) $(fsw b)" '"3 0" "3 0" "3 0" "3 0"')" "$P1 then $(fsw d) $(fsw b), $(ids)"
check "P: ... d and b alone there, numbers unique" "$(is "$(J clients | jq '[.[] | select(.workspace.id == 3)] | length')$(uniq_ok && echo 1)" 21)" "$(geom) $(ids)"
rig_stop
setup
focus "$A"; fs "$A" set; sleep 1.2; AW=$(win a .workspace.id); S0=$(ids)
check "Q: a fullscreen on a trip, alone on $AW" "$(is "$(fsw a)" "\"$AW 2\"")" "$(fsw a) $S0"
C=$(addr_of c); move_to "$C" "$AW"; sleep 1; Q1="$(fsw a) $(fsw c)"; sleep 3; settle 3 ids
check "Q: c moved onto the trip's desktop by the dispatcher: a out of fullscreen, stays there with c, still so 3 s later" "$(is "$Q1 $(fsw a) $(fsw c)" "\"$AW 0\" \"$AW 0\" \"$AW 0\" \"$AW 0\"")" "$Q1 then $(fsw a) $(fsw c), $S0 -> $(ids)"
check "Q: ... nothing flew home or was paid back: b alone on 1, a and c on $AW, d alone, numbers unique" "$(is "$(win b .workspace.id) $(J workspaces | jq -r "[.[] | select(.id == $AW) | .windows] | .[0]") $(J clients | jq -r "[.[] | select(.workspace.id == $(win d .workspace.id))] | length") $(trace | grep -c 'paying back') $(uniq_ok && echo 1)" "1 2 1 0 1")" "$(ids); $(trace | grep -m1 'trip ends here' | cut -d' ' -f3-)"
D=$(addr_of d); DW=$(win d .workspace.id); go "$DW"; sleep 0.4; focus "$D"; mx "$D" set; sleep 1
B=$(addr_of b); move_to "$B" "$DW"; sleep 1; R1="$(fsw d)"; sleep 3
check "R: b moved onto maximized d's desktop by the dispatcher: d un-maximized, both there, still so 3 s later" "$(is "$R1 $(fsw d) $(fsw b)" "\"$DW 0\" \"$DW 0\" \"$DW 0\"")" "$R1 then $(fsw d) $(fsw b), $(ids)"
rig_stop

# Mosaic: the windows already on the target are not resized; the moved one is at its size
rig_start; trace_on; cfg '{general={layout="mosaic"}}'
go 2; kw m3 700 450; go 1; kw m1 700 450; kw m2 600 400; $R ptr move 700 1000 >/dev/null; settle 3 geom
SZ=$(J clients | jq -r '[.[] | select(.class == "m1" or .class == "m2") | "\(.class) \(.size[0])x\(.size[1])"] | sort | join(" ")')
M3=$(addr_of m3); go 2; sleep 0.4; focus "$M3"; fs "$M3" set; sleep 1.2; go 1; sleep 0.8
dbg movehere m3 >/dev/null; sleep 1.5; settle 3 geom
SZ2=$(J clients | jq -r '[.[] | select(.class == "m1" or .class == "m2") | "\(.class) \(.size[0])x\(.size[1])"] | sort | join(" ")')
check "E: Mosaic, settled m3 moved here by the dock menu: on 1, not fullscreen, at its 696x446" "$(is "$(win m3 '"\(.workspace.id) \(.fullscreen) \(.size[0])x\(.size[1])"')" '"1 0 696x446"')" "$(geom)"
check "E: ... m1 and m2 not resized" "$(is "$SZ2" "$SZ")" "$SZ2 (was $SZ)"
# K: the same for a MAXIMIZED m3: un-maximized at its own size, m1 and m2 not resized
M3=$(addr_of m3); move_to "$M3" 2; sleep 0.8; settle 3 geom; go 2; sleep 0.4; focus "$M3"
ev "hl.dispatch(hl.dsp.window.fullscreen({ window = [[address:$M3]], mode = \"maximized\", action = \"set\" }))"; sleep 1.2; go 1; sleep 0.8
SZ=$(J clients | jq -r '[.[] | select(.class == "m1" or .class == "m2") | "\(.class) \(.size[0])x\(.size[1])"] | sort | join(" ")')
K0=$(win m3 '"\(.workspace.id) \(.fullscreen)"')
dbg movehere m3 >/dev/null; sleep 1.5; settle 3 geom
SZ2=$(J clients | jq -r '[.[] | select(.class == "m1" or .class == "m2") | "\(.class) \(.size[0])x\(.size[1])"] | sort | join(" ")')
check "K: Mosaic, m3 maximized alone on 2 ($K0) moved here by the dock menu: on 1, not maximized, at its 696x446" "$(is "$(win m3 '"\(.workspace.id) \(.fullscreen) \(.size[0])x\(.size[1])"')" '"1 0 696x446"')" "$(geom)"
check "K: ... m1 and m2 not resized" "$(is "$SZ2" "$SZ")" "$SZ2 (was $SZ)"
# T: m3 fullscreen alone on 2 again; m2 moved onto 2 by the dock menu: m3 back at its 696x446, m2 at its own, m1 not resized
move_to "$M3" 2; sleep 0.8; settle 3 geom; go 2; sleep 0.4; focus "$M3"; fs "$M3" set; sleep 1.2
M1S=$(win m1 '"\(.size[0])x\(.size[1])"'); M2S=$(win m2 '"\(.size[0])x\(.size[1])"' | tr -d '"')
dbg movehere m2 >/dev/null; sleep 1.5; settle 3 geom; sleep 1.5
check "T: Mosaic, m2 moved onto fullscreen m3's desktop: m3 out, at 696x446; m2 there at its size; m1 not resized" "$(is "$(win m3 '"\(.workspace.id) \(.fullscreen) \(.size[0])x\(.size[1])"') $(win m2 '"\(.workspace.id) \(.size[0])x\(.size[1])"') $(win m1 '"\(.size[0])x\(.size[1])"')" "\"2 0 696x446\" \"2 $M2S\" $M1S")" "$(geom) (m2 was $M2S, m1 $M1S)"
rig_stop

# a fullscreen GAME (an .exe under XWayland) moved onto a populated desktop leaves
# fullscreen too, and stays out: not put back, not sent to the dock
xdisplay() { hlog 4000 | grep -o 'DISPLAY: :[0-9]*' | tail -1 | grep -o ':[0-9]*$'; }
cc -O2 -o "$GOUT/wine_state" "$ROOT/tests/rig/xstate/wine_state.c" $(pkg-config --cflags --libs xcb) 2>/dev/null && chmod 755 "$GOUT" "$GOUT/wine_state"
if [ -x "$GOUT/wine_state" ]; then
    rig_start; trace_on; go 1; kw a; kw b
    wait_for 6 '[ -n "$(xdisplay)" ]' || { $R win env DISPLAY=:99 true >/dev/null 2>&1; wait_for 6 '[ -n "$(xdisplay)" ]'; }
    go 3; $R win env DISPLAY="$(xdisplay)" "$GOUT/wine_state" fs 14 >/dev/null
    wait_for 5 "[ \"\$(win wine_state.exe .fullscreen)\" = 2 ]"; sleep 1
    check "G: the game alone on 3, fullscreen" "$(is "$(win wine_state.exe '"\(.workspace.id) \(.fullscreen)"')" '"3 2"')" "$(geom)"
    go 1; sleep 0.6; dbg movehere wine_state.exe >/dev/null; sleep 1; G1=$(win wine_state.exe '"\(.workspace.id) \(.fullscreen)"'); sleep 2.5
    G2=$(win wine_state.exe '"\(.workspace.id) \(.fullscreen)"')
    check "G: moved onto 1 by the dock menu: out of fullscreen, there, and still so 2.5 s later" "$(is "$G1 $G2" '"1 0" "1 0"')" "$G1 then $G2, $(ids)"
    rig_stop
    # S: an ordinary window moved onto the fullscreen GAME's desktop: the game leaves fullscreen and stays out
    rig_start; trace_on; go 1; kw a; kw b
    wait_for 6 '[ -n "$(xdisplay)" ]' || { $R win env DISPLAY=:99 true >/dev/null 2>&1; wait_for 6 '[ -n "$(xdisplay)" ]'; }
    go 3; $R win env DISPLAY="$(xdisplay)" "$GOUT/wine_state" fs 14 >/dev/null
    wait_for 5 "[ \"\$(win wine_state.exe .fullscreen)\" = 2 ]"; sleep 1
    GW=$(win wine_state.exe .workspace.id)
    dbg movehere b >/dev/null; sleep 1; S1="$(win wine_state.exe '"\(.workspace.id) \(.fullscreen)"')"; sleep 3
    S2="$(win wine_state.exe '"\(.workspace.id) \(.fullscreen)"') $(win b '"\(.workspace.id) \(.fullscreen)"')"
    check "S: b moved onto the fullscreen game's desktop ($GW) by the dock menu: the game out, both there, still so 3 s later" "$(is "$S1 $S2" "\"$GW 0\" \"$GW 0\" \"$GW 0\"")" "$S1 then $S2, $(ids)"
    rig_stop
    # L: an X11 client that MAXIMIZES itself (wine_state max), alone on 3, moved onto 1: un-maximized, and stays so
    rig_start; trace_on; go 1; kw a; kw b
    wait_for 6 '[ -n "$(xdisplay)" ]' || { $R win env DISPLAY=:99 true >/dev/null 2>&1; wait_for 6 '[ -n "$(xdisplay)" ]'; }
    go 3; $R win env DISPLAY="$(xdisplay)" "$GOUT/wine_state" max 14 >/dev/null
    wait_for 5 "[ \"\$(win wine_state.exe .fullscreen)\" = 1 ]"; sleep 1
    check "L: the client alone on 3, maximized (by itself)" "$(is "$(win wine_state.exe '"\(.workspace.id) \(.fullscreen)"')" '"3 1"')" "$(geom)"
    go 1; sleep 0.6; dbg movehere wine_state.exe >/dev/null; sleep 1; L1=$(win wine_state.exe '"\(.workspace.id) \(.fullscreen)"'); sleep 2.5
    L2=$(win wine_state.exe '"\(.workspace.id) \(.fullscreen)"')
    check "L: moved onto 1 by the dock menu: un-maximized, there, and still so 2.5 s later" "$(is "$L1 $L2" '"1 0" "1 0"')" "$L1 then $L2, $(ids); $(trace | grep -c 'maximized itself again') re-asserts"
    rig_stop
else
    subskip "G: the game" "cannot build wine_state (xcb headers?)"
fi
gate_end
