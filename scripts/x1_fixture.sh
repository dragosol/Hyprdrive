#!/usr/bin/env bash
# X1 fixture: N kitty windows spread over several workspaces, on a HEADLESS
# output.
#
# Two things are deliberate and cost previous fires runs when they were not:
#   - kitty, never foot (user instruction; foot frosts ~2.6x weaker).
#   - HEADLESS-1 with Virtual-1 DISABLED. Virtual-1 drops to ~1 frame per 5s
#     with no SPICE consumer attached, and while it is enabled and not
#     completing page flips EVERY output starves, headless included. A stress
#     test that never renders is not a stress test -- it would exercise the
#     plugin's bookkeeping and none of its render path.
#
# Classes are X1Wnn so a query prefix of "X1W" matches every window and a
# longer prefix matches a known, countable subset.
#
# Usage: x1_fixture.sh [N=24] [WORKSPACES=3]
set -u
N=${1:-24}
NWS=${2:-3}
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/x1; mkdir -p $OUT

ov() { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }

ov off; sleep 1
pkill -x kitty 2>/dev/null; pkill -x wf-recorder 2>/dev/null; sleep 1.5

# `hyprctl output create headless` is NOT idempotent. Calling this script four
# times created HEADLESS-1..4, and the spawn loop below then scattered the
# fixture across all four -- so the overview under test showed a QUARTER of the
# windows the run claimed, and every capture still looked plausible. It also
# produced two workspaces sharing one id, which reads as state corruption and
# is not. Tear the headless outputs down and build exactly one, every run.
hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = false})" >/dev/null 2>&1
sleep 1.5
for m in $(hyprctl monitors all -j | python3 -c "
import json,sys
print(' '.join(m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')))"); do
    hyprctl output remove "$m" >/dev/null 2>&1; sleep 0.4
done
sleep 1
hyprctl output create headless >/dev/null 2>&1; sleep 1.5
MON=$(hyprctl monitors -j | python3 -c "
import json,sys
hs=[m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')]
print(hs[0] if len(hs)==1 else '')")
[ -n "$MON" ] || { echo "ABORT: expected exactly one headless output"; exit 1; }
hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = true})" >/dev/null 2>&1
sleep 1.5
NMON=$(hyprctl monitors -j | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")
[ "$NMON" = "1" ] || { echo "ABORT: $NMON enabled monitors, fixture would scatter"; exit 1; }
echo "output: $MON (sole enabled monitor, Virtual-1 disabled)"

# Colours cycle, and with enough windows per desktop the cycle REPEATS -- six
# magenta tiles on one desktop merge into one bounding box and destroy any
# attempt to measure a grab point. So window 0 gets pure red, used by nothing
# else, and it is the drag subject. Identity still comes from the class.
COLS=('#ff00ff' '#00ff00' '#0000ff' '#ffff00' '#00ffff' '#ff8800' '#8888ff' '#ffffff')
MARKER='#ff0000'
i=0
while [ $i -lt $N ]; do
    WS=$(( i % NWS + 1 ))
    C=${COLS[$(( i % 8 ))]}
    [ $i -eq 0 ] && C=$MARKER
    CLS=$(printf 'X1W%02d' $((i+1)))
    hyprctl dispatch "hl.dsp.focus({monitor = \"$MON\"})" >/dev/null 2>&1
    sleep 0.15
    hyprctl dispatch "hl.dsp.focus({workspace = $WS})" >/dev/null 2>&1
    sleep 0.15
    setsid kitty -c NONE --class "$CLS" -o background="$C" -o background_opacity=1.0 \
        -o confirm_os_window_close=0 --hold sh -c 'clear' >/dev/null 2>&1 </dev/null &
    sleep 0.85
    i=$((i+1))
done
hyprctl dispatch 'hl.dsp.focus({workspace = 1})' >/dev/null 2>&1
sleep 1.5

GOT=$(hyprctl clients -j | python3 -c "
import json,sys; print(sum(1 for c in json.load(sys.stdin) if c['class'].startswith('X1W')))")
echo "fixture: $GOT/$N tiles"
[ "$GOT" = "$N" ] || { echo "ABORT: fixture is $GOT/$N, refusing to stress an unknown state"; exit 1; }

hyprctl clients -j > $OUT/fixture-clients.json
hyprctl workspaces -j | python3 -c "
import json,sys
for w in sorted(json.load(sys.stdin), key=lambda x: x['id']): print(w['id'], w['windows'])"
echo X1_FIXTURE_OK
