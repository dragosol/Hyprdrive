#!/bin/bash
# Repro for the "segfault at X ip X error 14" compositor crash. Runs IN THE GUEST.
# Signature: the faulting address equals the instruction pointer, i.e. a call
# through a dangling function pointer, and it lands in the mmap range where the
# plugin is loaded. Hits roughly 2 runs in 3; the same signature is in the journal
# from 02:07, 02:10, 02:40 and 03:14 on 2026-08-07, all on builds that predate the
# OverviewInternal split, so it is NOT a refactor regression.
#
# Sequence that provokes it: search results on screen -> a TIGHT backspace loop
# (no sleep) that empties the query and closes the overview -> a mouse move. The
# move is what dies, so the suspect is a listener still firing against torn-down
# overview state. Pacing the backspaces 0.4s apart does NOT reproduce it.
#
# Reuses x26_open.sh as the opener. Do not write a new one -- a bespoke opener is
# how the last rig produced a false negative.
set -u
mkdir -p /mnt/host/x26   # x26_open.sh writes grim+clients dumps there; missing dir silently skips them and the repro goes cold
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1        # RIG_SIG0 is the per-run baseline; alive_or_die re-reads the sig each step
bash "$(dirname "$0")/x26_open.sh" >/dev/null 2>&1
alive_or_die "during open"
ydotool type "fire"; sleep 1.2
ydotool mousemove -a -x 640 -y 300; sleep 0.8
alive_or_die "on hover"
for i in $(seq 10); do ydotool key 14:1 14:0; done
sleep 1.0
alive_or_die "tight backspace loop"
ydotool mousemove -a -x 700 -y 300; sleep 0.9
alive_or_die "on the hover after"
echo SURVIVED
