#!/usr/bin/env bash
# fs_beside -- a window opened from a fullscreen app opens BESIDE it, visible at once, the app stays fullscreen.
# Protects (designed behaviours, Fullscreen [11-05..11-09]): "a window opened
# from a fullscreen app opens beside it, visible at once, and the app stays
# fullscreen"; tests/rig/fsdesk/README.md case 2.
# Asserts, from 1:{a,b} 2:{c} 3:{d}, a fullscreen on 2 (c, d bumped to 3, 4):
#   - a window the compositor launches while a is focused lands on 3, a desktop
#     of its own right after a's, and 3 is shown at once
#   - a is still fullscreen on 2
#   - the new window closed and 2 looked at again: the place made for it is paid
#     back (trace "paying back place 3"); a leaves fullscreen: 1:2 2:1 3:1
# Control (--control): fullscreen_desktop = "stay" -- the new window opens on
# a's own desktop and is not shown beside it. Recorded 2026-11-11 on 3ad1da3:
# control FAILS as it must.
source "$(dirname "$0")/lib.sh"
gate_begin fsb
rig_start
[ "$CONTROL" = 1 ] && cfg '{plugin={hyprdrive={general={fullscreen_desktop="stay"}}}}'
trace_on
go 1; kw a; kw b; go 2; kw c; go 3; kw d; go 1; sleep 0.5
A=$(addr_of a); START=$(ids)
focus "$A"; fs "$A" set; sleep 1.2; AW=$(win a .workspace.id)
check "the app went to 2" "$(is "$AW" 2)" "a on $AW"
kexec beside; sleep 0.8; settle 3 ids
BW=$(win beside .workspace.id)
check "the new window opens on the desktop right after the app's" "$(is "$BW" $((AW + 1)))" "app on $AW, new on $BW, $(ids)"
check "the new window is shown at once" "$(is "$(shown)" "$BW")" "shown $(shown)"
check "the app stays fullscreen" "$(is "$(win a .fullscreen)" 2)" "a fullscreen=$(win a .fullscreen) on $(win a .workspace.id)"
check "the trace names it" "$(ge "$(trace | grep -c 'opened over fullscreen')" 1)" "$(trace | grep fsdesk | tail -2 | cut -d' ' -f3- | tr '\n' ';')"
close_win "$(addr_of beside)"; sleep 0.8; go "$AW"; sleep 1.5
fs "$A" unset; wait_for 6 "[ \"\$(ids)\" = '$START' ]"
check "closed and exited: everything back" "$(is "$(ids)" "$START")" "$(ids)"
check "the place made for it was paid back" "$(ge "$(trace | grep -c 'paying back place')" 2)" "$(trace | grep 'paying back' | cut -d' ' -f3- | tr '\n' ';')"
gate_end
