#!/usr/bin/env bash
# fs_cycles -- fullscreen desktops are SPAM-PROOF: 50 on/off cycles at ~1 Hz and 50 at key-repeat speed.
# Protects (designed behaviours, Fullscreen [11-05..11-09]): "all animated,
# reversible, spam-proof"; tests/rig/fsdesk/README.md case 1.
# Asserts, from 1:{a,b} 2:{c} 3:{d}:
#   - after 50 cycles at ~1 Hz (0.5 s on, 0.5 s off) the desktops are 1:2 2:1 3:1 again
#   - after 50 cycles at key-repeat speed (~30 ms apart) the same
#   - at EVERY sample (a background sampler, ~20/s) no two desktops share a
#     number and none is below 1
#   - the trace never says "a debt with no place" or "place -1"; the
#     desktop-number refusal log stays empty
# Control (--control): the same cycles with fullscreen_desktop = "free" (the
# app takes the next FREE desktop and nothing is owed back), whose ids differ
# after the first on (a on 4, not 2) -- the "moved to 2" check fails. Recorded
# 2026-11-11 on 3ad1da3: control FAILS as it must.
source "$(dirname "$0")/lib.sh"
gate_begin fsc
rig_start
[ "$CONTROL" = 1 ] && cfg '{plugin={hyprdrive={general={fullscreen_desktop="free"}}}}'
trace_on
go 1; kw a; kw b; go 2; kw c; go 3; kw d; go 1; sleep 0.5
A=$(addr_of a); START=$(ids)
check "start layout" "$(is "$START" '1:2 2:1 3:1')" "$START"
focus "$A"; fs "$A" set; sleep 0.8
check "first on: a moved to 2" "$(is "$(win a .workspace.id)" 2)" "a on $(win a .workspace.id), $(ids)"
fs "$A" unset; sleep 0.8
sampler_start ids sample_ids
for i in $(seq 49); do fs "$A" set; sleep 0.5; fs "$A" unset; sleep 0.5; done
wait_for 6 "[ \"\$(ids)\" = '$START' ]"; S1=$(ids)   # paid back ~1-2 s after the last off
for i in $(seq 50); do fs "$A" set; sleep 0.03; fs "$A" unset; sleep 0.03; done
wait_for 6 "[ \"\$(ids)\" = '$START' ]"; S2=$(ids)
n=$(sampler_stop ids); dups=$(grep -c DUP "$GOUT/ids.samp")
check "50 cycles at ~1 Hz return to the start" "$(is "$S1" "$START")" "$S1"
check "50 cycles at key-repeat speed return to the start" "$(is "$S2" "$START")" "$S2"
check "app home on 1, not fullscreen" "$(is "$(win a '"\(.workspace.id) \(.fullscreen)"')" '"1 0"')" "$(win a '"\(.workspace.id) \(.fullscreen)"')"
check "ids unique and >= 1 at every one of $n samples" "$(is "$dups" 0)" "$dups bad samples: $(grep -m1 DUP "$GOUT/ids.samp")"
check "sampler really sampled" "$(ge "$n" 300)" "$n samples"
bad=$(trace | grep -c 'debt with no place\|place -1')
check "trace: no debt without a place" "$(is "$bad" 0)" "$bad lines"
check "no desktop renumber refused" "$(is "$(refused | wc -l)" 0)" "$(refused | tail -1)"
gate_end
