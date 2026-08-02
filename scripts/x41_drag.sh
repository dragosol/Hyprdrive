#!/usr/bin/env bash
# usage: x41_drag.sh cancel GX GY        -> X41: drag and change your mind
#        x41_drag.sh move   GX GY TX TY  -> X42: drag onto another desktop's mini
#
# The press is HELD and the path JITTERS. A rig that presses and releases in the
# same instant never crosses the drag threshold and leaves the entire code path
# under test untouched -- that is how X16 was scored fixed while broken.
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/x41
MODE=$1; GX=$2; GY=$3; TX=${4:-0}; TY=${5:-0}
MON=$(hyprctl monitors -j | python3 -c "
import json,sys
print(next((m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')), ''))")

ov()  { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }
mv2() { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; }
walk(){ local n=14 i jx jy; for i in $(seq 1 $n); do
    jx=$(( (i % 3) * 8 - 8 )); jy=$(( (i % 2) * 11 - 5 ))
    mv2 $(( $1 + ($3 - $1) * i / n + jx )) $(( $2 + ($4 - $2) * i / n + jy )); sleep 0.04; done; }

hyprctl clients -j > $OUT/pre-$MODE.json
ov off; sleep 1.2
ov on;  sleep 3

mv2 $GX $GY; sleep 0.5
ydotool click 0x40; sleep 0.12
if [ "$MODE" = cancel ]; then
    walk $GX $GY $((GX-150)) $((GY+90)); sleep 0.3
    grim -o $MON $OUT/mid-cancel.png
    walk $((GX-150)) $((GY+90)) $((GX-50)) $((GY+30))
else
    walk $GX $GY $TX $TY; sleep 0.4
    grim -o $MON $OUT/mid-move.png
    walk $TX $TY $TX $TY
fi
sleep 0.8
ydotool click 0x80; sleep 2.5
hyprctl clients -j > $OUT/post-$MODE.json
ov off; sleep 1.2
grim -o $MON $OUT/after-$MODE.png

python3 - "$MODE" <<'EOF'
import json, sys
mode = sys.argv[1]
def mark(p):
    return next((c for c in json.load(open(p)) if c['class'] == 'MARK'), None)
a = mark('/mnt/host/x41/pre-%s.json' % mode)
b = mark('/mnt/host/x41/post-%s.json' % mode)
if not a or not b:
    print('ABORT: MARK missing'); sys.exit(1)
print('MARK before: ws=%s at=%s size=%s' % (a['workspace']['id'], a['at'], a['size']))
print('MARK after : ws=%s at=%s size=%s' % (b['workspace']['id'], b['at'], b['size']))
same = a['size'] == b['size']
print('SIZE_PRESERVED=%s  (%s -> %s)' % (same, a['size'], b['size']))
if mode == 'move':
    print('WORKSPACE_CHANGED=%s  (%s -> %s)' % (a['workspace']['id'] != b['workspace']['id'], a['workspace']['id'], b['workspace']['id']))
    print('POS_PRESERVED=%s  (%s -> %s)' % (a['at'] == b['at'], a['at'], b['at']))
EOF
