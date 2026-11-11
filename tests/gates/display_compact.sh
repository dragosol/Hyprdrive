#!/usr/bin/env bash
# display_compact -- a display change removes the empty desktops between the ones with windows.
# Protects: the owner's report 2026-11-11 (desktops left at 21, 22, 28, 29, 30
# after an output change), fix 3ad1da3; tests/rig/fsdesk/README.md case 6. It
# guards the Fullscreen [11-05..11-09] rule "removes the desktop it made" too:
# compaction must not eat a trip's place.
# Asserts:
#   A. one window each on 21 22 28 29 30, 22 shown; scale 1.25 -> within 2 s the
#      populated desktops are 1 2 3 4 5, each window's new number is its old
#      desktop's rank, 22 is still shown (as 2), the refusal log has exactly one
#      "the monitor layout changed" line; scale 1 again -> nothing moves, no new line
#   B. the same five, an EMPTY 25 shown: -> 1..5, and the shown desktop is kept (as 6)
#   C. two windows on 21, one each on 22 28 29 30; one of the 21 pair goes
#      fullscreen (to 22, the rest bumped); scale 1.25 -> 1..6 with the app alone
#      on 2; it leaves fullscreen -> home on 1, populated 1..5
# Control: --so 8bb258c (scratchpad p3t/old.so, before 3ad1da3): nothing is
# compacted, A fails. Recorded 2026-11-11: the gate FAILS on it.
source "$(dirname "$0")/lib.sh"
gate_begin dsp
control_build "8bb258c, e.g. the scratchpad p3t/old.so"
scale() { ev "hl.monitor({ output = \"HEADLESS-1\", mode = \"preferred\", position = \"auto\", scale = $1 })"; }
five() { for n in 21 22 28 29 30; do go $n; kw "w$n"; done; [ "${1:-}" ] && { go 21; kw w21b; }; }
rank_ok() { # every window w<N> now sits on the rank of N among 21 22 28 29 30 (+offset for a trip)
    J clients | jq -r '.[] | "\(.class) \(.workspace.id)"' | awk -v off="${1:-0}" '
        BEGIN { r["w21"]=1; r["w21b"]=1; r["w22"]=2; r["w28"]=3; r["w29"]=4; r["w30"]=5 }
        { want = r[$1]; if (want > 1 && off) want += off; if ($1 in r && $2 != want) { bad = bad " " $1 "@" $2 "!=" want } }
        END { print (bad == "" ? "ok" : bad) }'; }

rig_start; trace_on
five; go 22; sleep 0.8
check "A: start 21 22 28 29 30" "$(is "$(pop)" '21 22 28 29 30')" "$(pop)"
scale 1.25; wait_for 3 "[ \"\$(pop)\" = '1 2 3 4 5' ]"
check "A: scale change -> 1 2 3 4 5" "$(is "$(pop)" '1 2 3 4 5')" "$(pop) / $(ids)"
check "A: each window on its old desktop's rank" "$(is "$(rank_ok)" ok)" "$(rank_ok)"
check "A: the shown desktop is still shown (22 -> 2)" "$(is "$(shown)" 2)" "shown $(shown)"
sleep 1; L1=$(refused | grep -c 'the monitor layout changed')
check "A: one refusal-log line for it" "$(is "$L1" 1)" "$L1: $(refused | tail -2 | tr '\n' ';')"
scale 1; sleep 2
check "A: scale 1 again: nothing moves" "$(is "$(pop)" '1 2 3 4 5')" "$(pop)"
check "A: and no new line" "$(is "$(refused | grep -c 'the monitor layout changed')" 1)" "$(refused | tail -2 | tr '\n' ';')"
rig_stop

rig_start
five; go 25; sleep 0.8
scale 1.25; wait_for 3 "[ \"\$(pop)\" = '1 2 3 4 5' ]"; sleep 0.3
check "B: shown empty 25: windows -> 1..5" "$(is "$(pop)" '1 2 3 4 5')" "$(pop)"
check "B: the shown empty desktop is kept, as 6" "$(is "$(shown)" 6)" "shown $(shown), $(ids)"
rig_stop

rig_start; trace_on
five pair; go 21; sleep 0.5
A=$(addr_of w21); focus "$A"; fs "$A" set; sleep 1.2
check "C: trip: app alone on 22, the rest bumped" "$(is "$(pop)" '21 22 23 29 30 31')" "$(pop)"
scale 1.25; wait_for 3 "[ \"\$(pop)\" = '1 2 3 4 5 6' ]"; sleep 0.3
check "C: scale change with a trip -> 1..6, app alone on 2" "$(is "$(pop) $(win w21 .workspace.id)" '1 2 3 4 5 6 2')" "$(pop), app on $(win w21 .workspace.id)"
check "C: its place is not closed by the compaction" "$(is "$(trace | grep -c 'closed by the compaction')" 0)" "$(trace | grep -m1 'closed by the compaction' | cut -d' ' -f3-)"
fs "$A" unset; wait_for 6 "[ \"\$(pop)\" = '1 2 3 4 5' ]"
check "C: out of fullscreen: home on 1, 1..5" "$(is "$(pop) $(win w21 .workspace.id)" '1 2 3 4 5 1')" "$(pop), app on $(win w21 .workspace.id)"
check "C: windows on their ranks" "$(is "$(rank_ok)" ok)" "$(rank_ok)"
gate_end
