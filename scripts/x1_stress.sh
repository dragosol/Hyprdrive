#!/usr/bin/env bash
# X1 -- break-proof stress test for the C++ overview plugin. KEEP THIS FILE.
#
# Spec §13.4 X1: many windows, heavy filtering, rapid desktop switching from
# inside the overview, and any other abuse a real user could inflict. The
# overview must not fall over, LEAK, or CORRUPT STATE.
#
# Those three words are the three checks, and each is measured:
#   fall over -- Hyprland's pid must be unchanged and hyprctl must still answer
#                after every phase. `gate` aborts the run at the first phase
#                that kills the compositor rather than reporting a later pass.
#   leak      -- VmRSS and open-fd count, sampled after every phase with the
#                overview CLOSED and settled, so the reading is steady-state.
#   corrupt   -- two different invariants, because the phases differ:
#                P1-P6 do not move windows, so the FULL state (address,
#                workspace, position, size, floating) must come back identical.
#                P7-P8 move windows on purpose, so the invariant is the weaker
#                but still sharp one: same set of addresses (nothing lost or
#                duplicated), every window on a real workspace, no zero sizes.
#
# EVERY PHASE THAT CAN SILENTLY NO-OP HAS A GATE, because on this rig they do:
#   - a press at screen centre lands in a GAP between tiles, the release reads
#     as a backdrop click and closes the overview. Grab points must be on a
#     measured tile box, and the drag phases assert the frame actually changed.
#   - the first version of this file captured the filter phase AFTER clearing
#     the query, so its "filtered" frame was identical to the unfiltered one and
#     proved nothing. P3 now captures with the query LIVE.
#   - "workspaces changed" is NOT proof a drag committed: the trailing empty
#     desktop appears and disappears on its own. Compare only workspaces that
#     hold windows.
#
# Run AFTER x1_fixture.sh, which leaves N windows and a live HEADLESS output.
# Rendering matters: on a starved output the plugin's render path never runs.
#
# Usage: x1_stress.sh [TAG=x1]
set -u
TAG=${1:-x1}
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/x1; mkdir -p $OUT

HPID=$(pgrep -x Hyprland | head -1)
[ -n "$HPID" ] || { echo "ABORT: no Hyprland process"; exit 1; }
MON=$(hyprctl monitors -j | python3 -c "
import json,sys
print(next((m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')), ''))")
[ -n "$MON" ] || { echo "ABORT: no headless output -- run x1_fixture.sh first"; exit 1; }

ov()   { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }
nav()  { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.navigate([[$1]]))" >/dev/null 2>&1; }
key()  { ydotool key "$1:1" "$1:0" 2>/dev/null; }
whl()  { ydotool mousemove -w -x 0 -y "$1" 2>/dev/null; }
mv2()  { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; }
walk() { local n=${5:-14} i; for i in $(seq 1 $n); do
    mv2 $(( $1 + ($3 - $1) * i / n )) $(( $2 + ($4 - $2) * i / n )); sleep 0.04; done; }
rss()  { awk '/VmRSS/{print $2}' /proc/$HPID/status 2>/dev/null || echo 0; }
fds()  { ls /proc/$HPID/fd 2>/dev/null | wc -l; }
alive(){ [ -d /proc/$HPID ] && hyprctl version >/dev/null 2>&1; }

# Only workspaces that HOLD windows -- the trailing empty desktop comes and
# goes by design and is not evidence of anything.
wsocc() { hyprctl workspaces -j | python3 -c "
import json,sys
w=[x for x in json.load(sys.stdin) if x['windows']>0]
print(' '.join('%d:%d'%(x['id'],x['windows']) for x in sorted(w,key=lambda k:k['id'])))"; }

snapfull() {
  hyprctl clients -j | python3 -c "
import json,sys
ws=[c for c in json.load(sys.stdin) if c['class'].startswith('X1W')]
for c in sorted(ws, key=lambda x: x['class']):
    print('%s %s ws=%d at=%s size=%s float=%d' % (
        c['class'], c['address'], c['workspace']['id'],
        tuple(c['at']), tuple(c['size']), c['floating']))"
}
snapset() {  # identity + sanity only; position/workspace may legitimately move
  hyprctl clients -j | python3 -c "
import json,sys
ws=[c for c in json.load(sys.stdin) if c['class'].startswith('X1W')]
for c in sorted(ws, key=lambda x: x['address']):
    ok = 'OK' if (c['size'][0]>0 and c['size'][1]>0 and c['workspace']['id']>0) else 'BAD'
    print('%s %s %s' % (c['address'], c['class'], ok))"
}

gate() {
  if ! alive; then echo "FAIL_FELL_OVER after phase: $1"; echo "X1_STRESS_VERDICT FAIL"; exit 2; fi
}
sample() {
  ov off; sleep 1.5
  printf 'SAMPLE %-14s rss=%s fds=%s clients=%s ws=%s\n' "$1" "$(rss)" "$(fds)" \
    "$(hyprctl clients -j | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')" \
    "$(hyprctl workspaces -j | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
}

FAILP7=0
echo "X1 STRESS  pid=$HPID  output=$MON  $(date -u +%FT%TZ)"
ov off; sleep 1.5
snapfull > $OUT/$TAG-snap-before.txt
NWIN=$(wc -l < $OUT/$TAG-snap-before.txt)
[ "$NWIN" -ge 12 ] || { echo "ABORT: only $NWIN X1W windows -- run x1_fixture.sh first"; exit 1; }
RSS0=$(rss); FD0=$(fds)
echo "baseline: windows=$NWIN rss=${RSS0}kB fds=$FD0 occ=$(wsocc)"

# --- P1: rapid toggle, 60 laps at 60ms -- far shorter than the open/close
# animation, so every toggle retargets one still in flight. This is the phase
# that finds state left behind by a lifecycle that never completed.
echo "PHASE P1 rapid-toggle $(date +%s.%N)"
for i in $(seq 1 60); do ov toggle; sleep 0.06; done
sleep 2.5; gate P1; sample P1

# --- P2: many windows, held open. Heaviest single frame the plugin draws.
echo "PHASE P2 many-windows-open $(date +%s.%N)"
ov on; sleep 3
grim -o $MON $OUT/$TAG-p2-open.png 2>/dev/null
echo "  open with $NWIN tiles, rss=$(rss)kB"
gate P2; sample P2

# --- P3: heavy filtering. ~280 keystrokes at 70ms, cycling queries that match
# everything, a subset, nothing, and the D-Bus app providers (the expensive
# path). 70ms is shorter than the results-band reflow, so each keystroke
# retargets an animation mid-flight. Captures below are the phase's own gate.
echo "PHASE P3 heavy-filter $(date +%s.%N)"
ov on; sleep 2.5
grim -o $MON $OUT/$TAG-p3-noquery.png 2>/dev/null
# x1w=45,2,17 | x1w0=+11 | zzz=44 | set=31,18,20 | calc=46,30,38,46
for lap in 1 2 3 4 5 6 7; do
  for q in "45 2 17" "45 2 17 11" "44 44 44" "31 18 20" "46 30 38 46" "45 2 17 3"; do
    for k in $q; do key $k; sleep 0.07; done
    sleep 0.35
    for k in $q; do key 14; sleep 0.05; done
    sleep 0.2
  done
done
# Leave a query LIVE for the capture. The previous revision cleared it first and
# the resulting frame was indistinguishable from the unfiltered one.
for k in 45 2 17 11; do key $k; sleep 0.1; done
sleep 2.5
grim -o $MON $OUT/$TAG-p3-query.png 2>/dev/null
for i in 1 2 3 4; do key 14; sleep 0.08; done
sleep 1.5
gate P3; sample P3

# --- P4: rapid desktop switching FROM INSIDE the overview, both input paths
# (the plugin's navigate dispatcher and the scroll wheel are different code).
# 200ms is inside the pan ease.
echo "PHASE P4 desktop-switch $(date +%s.%N)"
ov on; sleep 2
for lap in 1 2 3 4 5; do
  for i in 1 2 3 4; do nav right; sleep 0.2; done
  for i in 1 2 3 4; do nav left;  sleep 0.2; done
  for i in 1 2 3 4; do whl 1;     sleep 0.18; done
  for i in 1 2 3 4; do whl -1;    sleep 0.18; done
done
sleep 2; gate P4; sample P4

# --- P5: trailing-workspace churn. E8-f was a defect that ONLY appeared on a
# workspace created after the overview opened, and the trailing desktop is the
# only one in normal use that is born mid-overview. Ride past the end and back.
echo "PHASE P5 trailing-ws-churn $(date +%s.%N)"
ov on; sleep 2
for lap in $(seq 1 12); do
  for i in 1 2 3 4 5; do nav right; sleep 0.25; done
  for i in 1 2 3 4 5; do nav left;  sleep 0.25; done
done
sleep 2
echo "  workspaces mid-churn: $(hyprctl workspaces -j | python3 -c 'import json,sys;print(sorted(w["id"] for w in json.load(sys.stdin)))')"
gate P5; sample P5

# --- P6: abuse mix -- ordering bugs between subsystems only show up when the
# subsystems are driven at once.
echo "PHASE P6 abuse-mix $(date +%s.%N)"
for lap in 1 2 3 4 5; do
  ov on;   sleep 0.25
  key 45;  sleep 0.08; key 2; sleep 0.08     # typing into a half-open overview
  ov off;  sleep 0.18                        # ...closed before it settles
  ov on;   sleep 0.3
  key 1;   sleep 0.25                        # ESC mid-open-animation
  ov on;   sleep 0.4
  nav right; key 17; nav left; sleep 0.3     # navigate while a query is live
  key 14; key 14; key 14
  ov off;  sleep 0.3
done
sleep 1.5; gate P6; sample P6

# --- CHECKPOINT 1: P1-P6 moved nothing. Full state must be identical.
ov off; sleep 2.5
snapfull > $OUT/$TAG-snap-mid.txt

# --- P7: drag storm. The most stateful path in the plugin, and the one where a
# half-finished interaction can strand state.
#   GRAB is a MEASURED tile box (magenta ws1 tile, x=[210,559] y=[423,633]).
#   Screen centre is a GAP -- pressing there closes the overview instead.
echo "PHASE P7 drag-storm $(date +%s.%N)"
# Defaults are measured for the 8-tiles-on-ws1 layout. A different tile count
# reflows the grid and moves them, so they are env-overridable and x1_tilebox.sh
# re-measures them from a capture.
GX=${GX:-384}; GY=${GY:-528}; TX=${TX:-1150}; TY=${TY:-190}
# A drag that MISSES a tile releases on the backdrop, which switches desktop and
# closes the overview -- so a later lap would grab from a different workspace's
# grid than the one the tile box was measured on. Re-assert ws1 before each lap.
ws1() { hyprctl dispatch 'hl.dsp.focus({workspace = 1})' >/dev/null 2>&1; sleep 0.5; }
ws1
ov on; sleep 2.5
grim -o $MON $OUT/$TAG-p7-rest.png 2>/dev/null

# P7a: 8 non-committing drags -- press the tile, walk a wide loop, release back
# where it started. Nothing moves, so the grid layout (and therefore the grab
# point) stays valid for every lap.
for lap in 1 2 3 4 5 6 7 8; do
  mv2 $GX $GY; sleep 0.35
  ydotool click 0x40 >/dev/null 2>&1; sleep 0.25
  walk $GX $GY 1500 800 8
  # Capture HERE, with the tile far from its slot. Capturing after the walk
  # back to the grab point shows the tile home again and reads as a no-op --
  # that mistake made this phase unfalsifiable once already.
  [ $lap = 1 ] && { sleep 0.4; grim -o $MON $OUT/$TAG-p7-middrag.png 2>/dev/null; }
  walk 1500 800 700 300 8
  walk 700 300 $GX $GY 8
  sleep 0.25
  ydotool click 0x80 >/dev/null 2>&1; sleep 0.7
done
sleep 1.5
echo "  after 8 loop-drags: occ=$(wsocc)"
gate P7a

# P7b: drag INTERRUPTED -- close the overview with the button still down, then
# release into nothing. This is the abuse most likely to strand drag state.
for lap in 1 2 3; do
  ws1; ov on; sleep 1.8
  mv2 $GX $GY; sleep 0.35
  ydotool click 0x40 >/dev/null 2>&1; sleep 0.25
  walk $GX $GY 1100 400 8
  ov off; sleep 0.4
  ydotool click 0x80 >/dev/null 2>&1; sleep 1.0
done
sleep 1.5
echo "  after 3 interrupted drags: occ=$(wsocc)"
gate P7b

# P7c: committing drops onto the strip. Each drop empties a slot and reflows the
# grid, so the fixed grab point drifts off a tile after a while -- that is why
# this is 3 laps and why each is gated on the occupancy actually changing.
COMMITS=0
for lap in 1 2 3; do
  ws1; ov on; sleep 2.2
  B=$(wsocc)
  mv2 $GX $GY; sleep 0.35
  ydotool click 0x40 >/dev/null 2>&1; sleep 0.25
  walk $GX $GY $((GX-80)) $((GY-120)) 6
  walk $((GX-80)) $((GY-120)) $TX $TY 12
  sleep 0.9
  ydotool click 0x80 >/dev/null 2>&1; sleep 1.8
  A=$(wsocc)
  [ "$B" != "$A" ] && COMMITS=$((COMMITS+1))
  echo "  drop lap$lap: $B -> $A"
  ov off; sleep 0.8
done
echo "  committed drops: $COMMITS/3"
# A drop phase that commits nothing has stressed nothing. Fail loudly rather
# than let the run report a pass earned by a no-op.
[ "$COMMITS" -ge 1 ] || { echo "  P7c: FAIL -- no drop committed, phase is a no-op"; FAILP7=1; }
gate P7c; sample P7

# --- P8: map/unmap storm. Windows born and killed while the overview is open.
# E8-f proved the plugin gets objects created after open wrong, so hammer it.
echo "PHASE P8 map-unmap-storm $(date +%s.%N)"
ov on; sleep 2
for lap in 1 2 3 4; do
  setsid kitty -c NONE --class X1TRANSIENT -o background='#00ffaa' \
    -o background_opacity=1.0 --hold sh -c 'clear' >/dev/null 2>&1 </dev/null &
  sleep 1.8
  [ $lap = 1 ] && grim -o $MON $OUT/$TAG-p8-transient.png 2>/dev/null
  hyprctl clients -j | python3 -c "
import json,sys,subprocess
for c in json.load(sys.stdin):
    if c['class']=='X1TRANSIENT': subprocess.run(['kill',str(c['pid'])])" 2>/dev/null
  sleep 1.5
done
sleep 2; gate P8; sample P8

# --- VERIFY
echo "PHASE VERIFY $(date +%s.%N)"
ov off; sleep 3
snapfull > $OUT/$TAG-snap-after.txt
snapset  > $OUT/$TAG-set-after.txt
RSS1=$(rss); FD1=$(fds)

# Still WORKS, not merely still running.
ov on; sleep 3
grim -o $MON $OUT/$TAG-final-open.png 2>/dev/null
ov off; sleep 2
grim -o $MON $OUT/$TAG-final-closed.png 2>/dev/null

FAIL=${FAILP7:-0}
echo "--- RESULTS ---"
alive && echo "alive:     PASS (pid $HPID still answering)" || { echo "alive:     FAIL"; FAIL=1; }

if diff -q $OUT/$TAG-snap-before.txt $OUT/$TAG-snap-mid.txt >/dev/null; then
  echo "state P1-P6: PASS ($NWIN windows, identical address/ws/at/size/float)"
else
  echo "state P1-P6: FAIL -- non-mutating phases moved something:"
  diff $OUT/$TAG-snap-before.txt $OUT/$TAG-snap-mid.txt | head -20
  FAIL=1
fi

NAFTER=$(wc -l < $OUT/$TAG-set-after.txt)
NBAD=$(grep -c BAD $OUT/$TAG-set-after.txt || true)
ADDRB=$(awk '{print $2}' $OUT/$TAG-snap-before.txt | sort | md5sum)
ADDRA=$(awk '{print $1}' $OUT/$TAG-set-after.txt | sort | md5sum)
if [ "$NAFTER" = "$NWIN" ] && [ "$NBAD" = "0" ] && [ "$ADDRB" = "$ADDRA" ]; then
  echo "state P7-P8: PASS (same $NWIN addresses, none lost/duplicated, all sane)"
else
  echo "state P7-P8: FAIL windows=$NAFTER/$NWIN bad=$NBAD addrset_match=$([ "$ADDRB" = "$ADDRA" ] && echo yes || echo no)"
  FAIL=1
fi

DR=$(( RSS1 - RSS0 )); DF=$(( FD1 - FD0 ))
PCT=$(python3 -c "print(round(100.0*$DR/max($RSS0,1),1))")
echo "memory:    rss ${RSS0} -> ${RSS1} kB (delta ${DR} kB, ${PCT}%)"
echo "fds:       ${FD0} -> ${FD1} (delta ${DF})"
[ "$DR" -lt 65536 ] || { echo "memory:    FAIL (>64MB growth)"; FAIL=1; }
[ "$DF" -lt 24 ]    || { echo "fds:       FAIL (fd growth suggests a leak)"; FAIL=1; }
echo "occupancy: $(wsocc)"
echo "captures in /mnt/host/x1/: $TAG-p3-noquery.png $TAG-p3-query.png $TAG-p7-rest.png $TAG-p7-middrag.png $TAG-final-open.png"
[ "$FAIL" = "0" ] && echo "X1_STRESS_VERDICT PASS" || echo "X1_STRESS_VERDICT FAIL"
exit $FAIL
