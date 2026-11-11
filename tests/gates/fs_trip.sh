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
#   5. in Mosaic, a1 a2 on 1: a1's round trip leaves both at their boxes (they
#      came back swapped before MosaicTripHold, 3ad1da3..d714041: a1 817,242
#      and a2 207,342 instead of 207,242 / 1117,342)
#   5b. three windows: the middle one's round trip, then the first one's: all
#      three at their boxes
#   5c. a3 closed on 1 during a1's trip: a1 comes home by the normal rules (the
#      trace says so), a1 and a2 keep their sizes, nothing overlaps
#   6. hybrid tiling (five 700x450): m1's and m3's round trips put every tile back
# Control (GATE_CONTROL=1): fullscreen_desktop = "stay" -> a stays on 1, checks
# 1 and 3 fail; in Mosaic each trip is made BY HAND (moved to 2 and back): the
# window arrives by the normal rules, so 5, 5b, 5c and 6 fail. Recorded
# 2026-11-11 (5..6 on the fix): control FAILS as it must.
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
# (MosaicTripHold.hpp). trip W: W's fullscreen round trip; CONTROL: the same
# trip BY HAND (moved to 2 and back, no fullscreen), which keeps the normal
# rules -- the window arrives at the end of the order, so the boxes change.
trip() {
    local A; A=$(addr_of "$1")
    if [ "$CONTROL" = 1 ]; then move_to "$A" 2; sleep 1; move_to "$A" 1; sleep 1.5
    else focus "$A"; fs "$A" set; wait_for 3 "[ \"\$(win $1 .workspace.id)\" != 1 ]"; sleep 1; ${2:-:}; fs "$A" unset; fi
    wait_for 4 "[ \"\$(win $1 .workspace.id)\" = 1 ]"; sleep 0.5; settle 4 geom
}
# no two windows of desktop 1 overlap, and the sizes are those of $1 (a geom)
sizes() { echo "$1" | tr '|' '\n' | awk '$2 == 1 {print $1, $4}' | sort | tr '\n' ' '; }
overlaps() { J clients | jq -r '.[] | select(.workspace.id == 1) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"' | python3 -I -c '
import sys
r = [list(map(int, l.split())) for l in sys.stdin if l.strip()]
print(sum(1 for i in range(len(r)) for j in range(i + 1, len(r))
          if min(r[i][0]+r[i][2], r[j][0]+r[j][2]) > max(r[i][0], r[j][0]) and min(r[i][1]+r[i][3], r[j][1]+r[j][3]) > max(r[i][1], r[j][1])))'; }
rig_start; cfg '{general={layout="mosaic"}}'; trace_on
go 2; kw b1 700 450; go 1; kw a1 700 450; kw a2 600 400
$R ptr move 700 1000 >/dev/null; settle 3 geom; G0=$(geom)
trip a1
check "5: mosaic, two windows: a1's round trip puts both back at their boxes" "$(is "$(geom)" "$G0")" "$(geom) -- was $G0"
kw a3 500 350; $R ptr move 700 1000 >/dev/null; settle 3 geom; G1=$(geom)
trip a2
check "5b: three windows: the middle one's round trip puts all three back" "$(is "$(geom)" "$G1")" "$(geom) -- was $G1"
trip a1
check "5b: three windows: the first one's round trip too" "$(is "$(geom)" "$G1")" "$(geom) -- was $G1"
# something changed on desktop 1 meanwhile (a3 closed during a1's trip): the
# normal rules -- a1 arrives as any window does; nobody is resized, nothing overlaps
trip a1 "close_win $(addr_of a3)"
check "5c: changed meanwhile: a1 arrives by the normal rules" "$(trace | grep -q 'trip: a1 home, but its desktop changed meanwhile' && echo 1)" "$(trace | grep 'trip:' | tail -3 | tr '\n' ' ')"
check "5c: ... a3 is gone, a1 and a2 keep their sizes, no overlap" "$(is "$(sizes "$(geom)") $(overlaps)" "$(sizes "$G1" | sed 's/a3 [0-9x]* //') 0")" "$(geom)"
rig_stop

# hybrid tiling (five 700x450 do not fit): a round trip puts the tiles back
rig_start; cfg '{general={layout="mosaic"}}'
go 1; for i in 1 2 3 4 5; do kexec m$i 700 450; sleep 0.5; done
$R ptr move 700 1000 >/dev/null; settle 3 geom; G3=$(geom)
check "6: five windows tile (m1 is not at its own 696x446)" "$(echo "$G3" | grep -q 'm1 1 [0-9,]* 696x446' && echo 0 || echo 1)" "$G3"
trip m1
check "6: hybrid tiling: m1's round trip puts every tile back" "$(is "$(geom)" "$G3")" "$(geom) -- was $G3"
trip m3
check "6: ... and m3's" "$(is "$(geom)" "$G3")" "$(geom) -- was $G3"
gate_end
