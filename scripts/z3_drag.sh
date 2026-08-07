#!/usr/bin/env bash
# usage: z3_drag.sh <GX> <GY> <TX> <TY> <tag>
#
# Grab MARK where the host found it and drop it on the strip mini the host found
# for the destination desktop. The press is HELD and the path JITTERS, for the
# reason x41_drag.sh already records: a press and release in the same instant
# never crosses the drag threshold, so the whole path under test is skipped and
# the rig scores a pass on code it never ran.
#
# The overview is assumed OPEN and showing the card MARK is on -- z3_setup.sh
# and z3_view.sh both leave it that way, and a drag that started with it closed
# would be measuring nothing.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/z3

GX=$1; GY=$2; TX=$3; TY=$4; TAG=$5
MON=$(hyprctl monitors -j | python3 -c "
import json,sys
print(next((m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')), ''))")

mv2()  { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; }
walk() { local n=16 i jx jy; for i in $(seq 1 $n); do
    jx=$(( (i % 3) * 8 - 8 )); jy=$(( (i % 2) * 11 - 5 ))
    mv2 $(( $1 + ($3 - $1) * i / n + jx )) $(( $2 + ($4 - $2) * i / n + jy )); sleep 0.05; done; }

mv2 $GX $GY; sleep 0.6
ydotool click 0x40; sleep 0.15
walk $GX $GY $TX $TY; sleep 0.4
grim -o $MON $OUT/$TAG-mid.png
walk $TX $TY $TX $TY; sleep 0.6
ydotool click 0x80; sleep 2.5

hyprctl clients -j > $OUT/clients-$TAG.json
python3 - "$TAG" <<'EOF'
import json, sys
tag = sys.argv[1]
c = next((c for c in json.load(open('/mnt/host/z3/clients-%s.json' % tag)) if c['class'] == 'MARK'), None)
print('MARK ws=%s at=%s size=%s' % (c['workspace']['id'], c['at'], c['size']) if c else 'MARK MISSING')
EOF
echo Z3_DRAG_OK
