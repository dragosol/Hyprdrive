#!/usr/bin/env bash
# fs_trip -- FULLSCREEN DESKTOPS, mode "next" (the default).
# Protects (project_hyprdrive_designed_behaviours, Fullscreen [11-05..11-09]):
#   "going fullscreen moves the app to desktop n if free, else n+1, reusing an
#    adjacent empty desktop instead of creating one; exit puts everything back
#    and removes the desktop it made"
# Asserts:
#   1. desktops 1:{a,b} 2:{c} 3:{d}; a goes fullscreen -> a alone on 2, c and d
#      bumped to 3 and 4, 2 is shown, a is fullscreen
#   2. a leaves fullscreen -> 1:{a,b} 2:{c} 3:{d} again (the made desktop is gone)
#   3. desktops 1:{a,b} 3:{d} (2 empty): a goes fullscreen -> it takes the free 2,
#      d stays on 3 (nothing bumped, no new desktop); exit -> 1:{a,b} 3:{d}
#   4. an app ALONE on its desktop stays there
#   5. in Mosaic, a1 a2 on 1: a1's round trip leaves both at their boxes
#      (KNOWN-FAIL on 3ad1da3: they come back swapped)
# Control (GATE_CONTROL=1): fullscreen_desktop = "stay" -> a stays on 1, checks
# 1 and 3 fail. Recorded 2026-11-11 on 3ad1da3: control FAILS as it must.
source "$(dirname "$0")/lib.sh"
gate_begin fst
rig_start
[ "$CONTROL" = 1 ] && cfg '{plugin={hyprdrive={general={fullscreen_desktop="stay"}}}}'
go 1; kw a; kw b; go 2; kw c; go 3; kw d; go 1; sleep 0.5
A=$(addr_of a); START=$(ids)
check "start layout" "$(is "$START" '1:2 2:1 3:1')" "$START"
focus "$A"; fs "$A" set
wait_for 3 "[ \"\$(win a .workspace.id)\" != 1 ]"; settle 3 ids
check "fullscreen: app alone on 2, the others bumped to 3, 4" "$(is "$(ids)" '1:1 2:1 3:1 4:1')" "$(ids), a on $(win a .workspace.id)"
check "fullscreen: app is on 2 and fullscreen" "$(is "$(win a '"\(.workspace.id) \(.fullscreen)"')" '"2 2"')" "$(win a '"\(.workspace.id) \(.fullscreen)"')"
check "fullscreen: 2 is shown" "$(is "$(shown)" 2)" "shown $(shown)"
fs "$A" unset; wait_for 3 "[ \"\$(ids)\" = '$START' ]"; settle 3 ids
check "exit: everything back, the made desktop removed" "$(is "$(ids)" "$START")" "$(ids)"
check "exit: app home on 1" "$(is "$(win a .workspace.id)" 1)" "a on $(win a .workspace.id)"

# a free n+1 is reused instead of a new desktop being made
move_to "$(addr_of c)" 3; go 1; settle 3 ids
S2=$(ids); check "free-2 layout" "$(is "$S2" '1:2 3:2')" "$S2"
focus "$A"; fs "$A" set; wait_for 3 "[ \"\$(win a .workspace.id)\" != 1 ]"; settle 3 ids
check "fullscreen with 2 free: app takes 2, 3 not bumped" "$(is "$(ids)" '1:1 2:1 3:2')" "$(ids)"
fs "$A" unset; wait_for 3 "[ \"\$(ids)\" = '$S2' ]"; settle 3 ids
check "exit with 2 free: back to 1, 3 untouched" "$(is "$(ids)" "$S2")" "$(ids)"

# alone on its desktop: stays
D=$(addr_of d); close_win "$(addr_of c)"; go 3; sleep 0.6; focus "$D"; fs "$D" set; sleep 1.2; settle 3 ids
check "an app alone on its desktop stays there" "$(is "$(win d '"\(.workspace.id) \(.fullscreen)"')" '"3 2"')" "$(win d '"\(.workspace.id) \(.fullscreen)"') ids $(ids)"
fs "$D" unset; sleep 0.5
rig_stop

# in Mosaic, "exit puts everything back" -- the windows too, at their boxes
rig_start; cfg '{general={layout="mosaic"}}'
[ "$CONTROL" = 1 ] && cfg '{plugin={hyprdrive={general={fullscreen_desktop="stay"}}}}'
go 2; kw b1 700 450; go 1; kw a1 700 450; kw a2 600 400
$R ptr move 700 1000 >/dev/null; settle 3 geom; G0=$(geom)
A=$(addr_of a1); focus "$A"; fs "$A" set; sleep 1.5; fs "$A" unset; sleep 2; settle 3 geom
check "mosaic: a round trip puts the windows back at their boxes" "$(is "$(geom)" "$G0")" "$(geom) -- was $G0" \
    "KNOWN-FAIL on 3ad1da3: a1 and a2 come back with their places swapped (needs the owner's ruling: is the mosaic re-pack on return designed?)"
gate_end
