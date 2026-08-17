#!/usr/bin/env bash
# v0_ws_gap_bound -- v1.1 item 0, the stability landmine the F3B report caught:
# a long session wedged the compositor with its main thread at 86% CPU inside
# CScrollOverview::ensureNoWorkspaceGaps -> CWorkspaceStateTracker::create.
#
# THE MECHANISM. X3 population parity is bought by MATERIALISING every missing
# workspace id below the highest live one, so the strip can lay out cells 1..N
# (scrollOverview.cpp, ensureNoWorkspaceGaps). The highest live id only ever
# ratchets UP over a session -- an output cycle leaves the session parked one
# desktop higher (measured: five headless_on/off cycles took maxID 1 -> 4), a
# window parked on a high desktop pins it there, and a user can jump to any id
# at all -- and nothing bounded the fill. Every open then re-created every
# missing id below it and handed the renderer a card and a blurred strip cell
# for each.
#
# WHAT IS ACTUALLY EXPENSIVE, measured rather than assumed (zrig/v6/item0):
# the open is cheap on both builds (7-8 ms at maxID 300) -- the cost is what the
# open LEAVES BEHIND. Compositor main-thread CPU with the overview UP, one
# window parked on desktop 300 and the session on desktop 1:
#       maxID    2      50     300     1000
#   parent    0.03    0.06    0.68     0.20   s of CPU per second
#   bounded   0.01    0.02    0.02     0.01
# and the hyprctl round trip at maxID 300 goes 28 ms -> 5 ms. (Parent falls
# again past ~500 only because the cells have shrunk below a pixel and the
# renderer drops them; the peak is where a cell is small enough to be free of
# nothing and large enough to be drawn.)
#
# THREE ARMS, and the first is why this cannot be "fixed" by deleting the fill:
#   PARITY  a normal session -- one window on desktop 5, viewing desktop 1 --
#           still shows five desktops plus the trailing empty (X3). Six
#           workspaces during the open, exactly as before the bound.
#   BOUND   the pathological session -- one window on desktop 300 -- must
#           materialise a BOUNDED population. Parent: 302 workspaces. Bounded:
#           34 (the cap, the real desktop 300, its trailing empty, the stash).
#   COST    and it must be bounded in CPU, which is the harm: main-thread CPU
#           while the overview is held open at maxID 300, against the same
#           measurement at maxID 2 taken in the same run as its control.
#
# STATE, NOT PIXELS: every number here is read from hyprctl and /proc, so the
# wallpaper, the frame rate and the capture pipeline cannot enter the verdict.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

OUT=${RIG_EVIDENCE:-/mnt/host/zrig}/v6/item0; mkdir -p "$OUT"
LOG=$OUT/gate.log; : > "$LOG"
FAIL=0
bad() { echo "FAIL $*" | tee -a "$LOG"; FAIL=1; }
say() { echo "$*" | tee -a "$LOG"; }

# The pathological desktop. 300 is where the parent's render cost peaks; the
# arm is about the SHAPE (bounded vs not), so any high id would do.
HIGH=300
# 32 phantoms + the real HIGH + its trailing empty + the minimize stash, plus
# slack for whatever the session already had. Parent scores 302 here.
BOUNDMAX=40
# Parent 0.68 s/s at maxID 300, bounded 0.02. Ten times either way.
CPUMAX=0.25

gate_slate v0_ws_gap_bound >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }
[ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_pause 30min

cleanup() {
    pkill -f -- '--class V0FIX' 2>/dev/null
    dsp "hl.dsp.focus({workspace = 1})"
    return 0
}
trap 'cleanup; [ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_resume' EXIT

sweep() {
    hyprctl clients -j 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('pid',0) > 0: print(c['pid'])" | xargs -r kill -9 2>/dev/null
    sleep 1.2
}
wscount() { hyprctl workspaces -j | python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }
hcpu()    { awk '{print ($14+$15)/100}' /proc/"$(pgrep -x Hyprland | head -1)"/stat; }

# Park one window on desktop N and come back to desktop 1: that is the whole
# synthetic state -- a live id far above the one being viewed, which is exactly
# what a session's ratchet leaves behind.
park() { # park N
    sweep
    dsp "hl.dsp.focus({workspace = 1})"; sleep 0.5
    dsp "hl.dsp.focus({workspace = $1})"; sleep 0.8
    setsid kitty -c NONE --class V0FIX -o background=#101820 -o background_opacity=1.0 \
        -o confirm_os_window_close=0 --hold sh -c 'sleep 3600' >/dev/null 2>&1 </dev/null &
    sleep 2.2
    dsp "hl.dsp.focus({workspace = 1})"; sleep 1.0
    hyprctl clients -j | grep -q V0FIX || { echo "rig: fixture did not map on desktop $1" >&2; return 1; }
    local m; m=$(hyprctl workspaces -j | python3 -c "import json,sys; print(max(w['id'] for w in json.load(sys.stdin)))")
    [ "$m" -ge "$1" ] || { echo "rig: wanted a live desktop $1, highest is $m" >&2; return 1; }
    return 0
}

# One open/hold/close lap. Prints "COUNT CPU_PER_S PING_MS OPEN_S".
lap() { # lap HOLD_SECS
    local hold=$1 c0 c1 t0 t1 p0 p1 n
    c0=$(hcpu); t0=$(date +%s.%N)
    timeout 300 hyprctl eval "return hl.dispatch(hl.plugin.$RIG_NS.overview([[on]]))" >/dev/null 2>&1
    t1=$(date +%s.%N)
    n=$(wscount)
    c1=$(hcpu)
    sleep "$hold"
    local c2; c2=$(hcpu)
    p0=$(date +%s.%N); timeout 120 hyprctl monitors -j >/dev/null 2>&1; p1=$(date +%s.%N)
    timeout 300 hyprctl eval "return hl.dispatch(hl.plugin.$RIG_NS.overview([[off]]))" >/dev/null 2>&1
    sleep 1.2
    awk -v n="$n" -v c1="$c1" -v c2="$c2" -v h="$hold" -v p0="$p0" -v p1="$p1" -v t0="$t0" -v t1="$t1" \
        'BEGIN{ printf "%s %.3f %.0f %.3f\n", n, (c2-c1)/h, (p1-p0)*1000, t1-t0 }'
}

############################################################ PARITY (X3 holds)
say "== PARITY: one window on desktop 5, viewing desktop 1"
park 5 || { echo "FAIL could not build the desktop-5 state"; exit 1; }
read -r P_N P_CPU P_PING P_OPEN <<< "$(lap 3)"
alive_or_die "after the parity lap"
say "   workspaces during open: $P_N (want 6: desktops 1-5, the trailing empty, and the stash counts too)"
# 6 real + the minimize stash if this session has one. Parity is the FLOOR: the
# five desktops and the trailing empty must all be there.
[ "$P_N" -ge 6 ] || bad "PARITY -- only $P_N workspaces during the open; the strip cannot show desktops 1-5 plus the trailing empty"
[ "$P_N" -le 9 ] || bad "PARITY -- $P_N workspaces for a five-desktop session"

############################################################ BOUND + COST
say "== BOUND: one window on desktop $HIGH, viewing desktop 1"
park "$HIGH" || { echo "FAIL could not build the desktop-$HIGH state"; exit 1; }
read -r H_N H_CPU H_PING H_OPEN <<< "$(lap 5)"
alive_or_die "after the bound lap"
say "   workspaces during open: $H_N (bound $BOUNDMAX; the un-bounded build materialises $((HIGH + 2)))"
say "   main-thread CPU held open: $H_CPU s/s (bound $CPUMAX)   round trip: ${H_PING} ms   open: ${H_OPEN}s"
[ "$H_N" -le "$BOUNDMAX" ] || bad "BOUND -- $H_N workspaces materialised for a session whose highest desktop is $HIGH"
awk -v v="$H_CPU" -v m="$CPUMAX" 'BEGIN{exit !(v<=m)}' \
    || bad "COST -- $H_CPU s of compositor main thread per second with the overview up (bound $CPUMAX)"

############################################################ CONTROL
# The same measurement on a session with nothing parked. Without it a green COST
# arm could just be a quiet VM: this is the floor the pathological state is
# supposed to reach, measured in the same run, on the same build, minutes apart.
say "== CONTROL: one window on desktop 1, nothing parked high"
park 1 || { echo "FAIL could not build the desktop-1 state"; exit 1; }
read -r C_N C_CPU C_PING C_OPEN <<< "$(lap 5)"
alive_or_die "after the control lap"
say "   workspaces during open: $C_N   main-thread CPU held open: $C_CPU s/s   round trip: ${C_PING} ms"
awk -v v="$C_CPU" -v m="$CPUMAX" 'BEGIN{exit !(v<=m)}' \
    || bad "CONTROL -- the plain one-desktop session already costs $C_CPU s/s; this VM is too loaded for the COST arm to mean anything"

say
say "PARITY  $P_N ws   BOUND $H_N ws   COST $H_CPU s/s vs control $C_CPU s/s"
[ $FAIL -eq 0 ] && say "v0_ws_gap_bound PASS"
exit $FAIL
