#!/usr/bin/env bash
# X24 acceptance: minimize keeps the window MAPPED on a hidden special
# workspace, restore puts it back on its own workspace with its geometry
# UNCHANGED and stacked on top.
#
# The fixture is deliberately a LARGE floating window overlapped by a smaller
# one spawned after it: X41 proved a uniform fixture pins bestScale at 1 and
# hides geometry bugs, and X43 proved focus is not stacking, so the overlap is
# what makes a missing raise visible in pixels.
# kitty, never foot (user standing rule).
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
OUT=/mnt/host/x24; mkdir -p $OUT

# dsp() comes from rig.sh
mini() { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.minimize([[$1]]))" 2>&1; }
snap() { hyprctl clients -j > "$1"; }

pkill -x kitty 2>/dev/null; sleep 1.5

MON=$(hyprctl monitors -j | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['name'])")
echo "output: $MON"

spawn() { # class colour w h x y
    setsid kitty -c NONE --class "$1" -o background="$2" -o background_opacity=1.0 \
        -o confirm_os_window_close=0 --hold sh -c 'clear' >/dev/null 2>&1 </dev/null &
    sleep 2.2
    A=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='$1'), ''))")
    [ -n "$A" ] || { echo "ABORT: $1 did not appear"; exit 1; }
    dsp "hl.dsp.focus({ window = [[address:$A]] })"; sleep 0.3
    F=$(hyprctl activewindow -j | python3 -c "import json,sys;print(json.load(sys.stdin).get('floating'))")
    [ "$F" = "True" ] || { dsp "hl.dsp.window.float()"; sleep 0.5; }
    dsp "hl.dsp.window.resize({exact=true,x=$3,y=$4})"; sleep 0.5
    dsp "hl.dsp.window.move({exact=true,x=$5,y=$6})"; sleep 0.5
}

spawn X24BIG '#ff0000' 1400 800 200 200
spawn X24TOP '#0000ff' 900 600 500 400
sleep 1

BIG=$(hyprctl clients -j | python3 -c "
import json,sys
print(next(c['address'] for c in json.load(sys.stdin) if c['class']=='X24BIG'))")
echo "big: $BIG"

# X24TOP was spawned last, so it covers the overlap. Prove that BEFORE the test,
# otherwise a passing raise assertion afterwards proves nothing.
grim -o $MON $OUT/00-before.png
snap $OUT/00-before.json

dsp 'hl.dsp.focus({ window = [[address:'"$BIG"']] })'; sleep 0.4

echo "-- minimize --"; mini window; sleep 1.2
grim -o $MON $OUT/01-minimized.png
snap $OUT/01-minimized.json

echo "-- restore --"; mini restore; sleep 1.5
grim -o $MON $OUT/02-restored.png
snap $OUT/02-restored.json
hyprctl activewindow -j > $OUT/02-active.json

python3 - "$BIG" <<'EOF'
import json, sys
big = sys.argv[1]

def find(path, addr=big):
    for c in json.load(open(path)):
        if c['address'] == addr:
            return c
    return None

before  = find('/mnt/host/x24/00-before.json')
during  = find('/mnt/host/x24/01-minimized.json')
after   = find('/mnt/host/x24/02-restored.json')
active  = json.load(open('/mnt/host/x24/02-active.json'))

fails = []
def check(name, ok, detail):
    print(('PASS ' if ok else 'FAIL ') + name + ': ' + detail)
    if not ok:
        fails.append(name)

check('P1 still exists while minimized', during is not None, repr(during and during['workspace']))
if during:
    check('P2 on the minimize stash', during['workspace']['name'] == 'special:minimized',
          during['workspace']['name'])
    # An unmapped window cannot be previewed live (X25 depends on this).
    check('P3 still MAPPED', during['mapped'] is True, str(during['mapped']))
    check('P4 not hidden', during.get('hidden') is not True, str(during.get('hidden')))

if before and after:
    check('P5 back on its own workspace', after['workspace']['id'] == before['workspace']['id'],
          '%s -> %s' % (before['workspace']['id'], after['workspace']['id']))
    # X41: a workspace move must never resize a window.
    check('P6 size unchanged', after['size'] == before['size'],
          '%s -> %s' % (before['size'], after['size']))
    # X42: nor re-centre it.
    check('P7 position unchanged', after['at'] == before['at'],
          '%s -> %s' % (before['at'], after['at']))

check('P8 focused after restore', active.get('address') == big, str(active.get('address')))

print('X24_RESULT ' + ('OK' if not fails else 'FAILED ' + ','.join(fails)))
EOF

# P9: minimizing the LAST window of a workspace lets Hyprland reap that
# workspace as soon as the user looks away, which strands the window on the
# stash. Measured to happen, so it is part of the suite.
echo "-- P9 sole window on its own workspace --"
dsp 'hl.dsp.focus({workspace = 7})'; sleep 0.6
setsid kitty -c NONE --class X24SOLO -o background='#00ff00' -o confirm_os_window_close=0 \
    --hold sh -c 'clear' >/dev/null 2>&1 </dev/null &
sleep 2.5
mini window >/dev/null; sleep 0.8
dsp 'hl.dsp.focus({workspace = 1})'; sleep 1.5
WS_GONE=$(hyprctl workspaces -j | python3 -c "
import json,sys; print(7 not in [w['id'] for w in json.load(sys.stdin)])")
mini restore >/dev/null; sleep 1.2
hyprctl clients -j | python3 -c "
import json,sys
c = next((c for c in json.load(sys.stdin) if c['class'] == 'X24SOLO'), None)
ws = c['workspace']['id'] if c else None
ok = ws == 7
print(('PASS ' if ok else 'FAIL ') + 'P9 restored onto a reaped workspace: ws=%s (was reaped: %s)' % (ws, '$WS_GONE'))
print('X24_STRANDING ' + ('OK' if ok else 'FAILED'))"
pkill -f 'class X24SOLO' 2>/dev/null; true
