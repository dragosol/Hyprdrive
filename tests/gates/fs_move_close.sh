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
# Control: --so the pre-fix build 8bb258c (scratchpad p3t/old.so): case B prints
# "paying back place -1" (fsdesk README; recorded 2026-11-11: the gate FAILS on it).
source "$(dirname "$0")/lib.sh"
gate_begin fsm
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
gate_end
