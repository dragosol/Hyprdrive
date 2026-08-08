#!/usr/bin/env bash
# E8-f probe: the user's exact gesture -- drag a window from the FIRST desktop
# onto the LAST (trailing, never-shown) desktop mini, then look at that mini
# WITH THE OVERVIEW STILL OPEN. Closing and reopening is the user's own
# workaround, so it is captured second as the control.
# Press is HELD and the path JITTERS (X16 lesson).
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/e8f; mkdir -p $OUT
GX=$1; GY=$2; TX=$3; TY=$4; TAG=${5:-run}
MON=$(hyprctl monitors -j | python3 -c "
import json,sys
print(next((m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')), ''))")
[ -n "$MON" ] || { echo ABORT: no headless output; exit 1; }

ov()  { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }
mv2() { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; }
walk(){ local n=14 i jx jy; for i in $(seq 1 $n); do
    jx=$(( (i % 3) * 8 - 8 )); jy=$(( (i % 2) * 11 - 5 ))
    mv2 $(( $1 + ($3 - $1) * i / n + jx )) $(( $2 + ($4 - $2) * i / n + jy )); sleep 0.04; done; }

ov off; sleep 1.2
ov on;  sleep 3
grim -o $MON $OUT/$TAG-0-rest.png

mv2 $GX $GY; sleep 0.5
ydotool click 0x40; sleep 0.12
walk $GX $GY $TX $TY; sleep 0.4
grim -o $MON $OUT/$TAG-1-middrag.png
walk $TX $TY $TX $TY
sleep 0.8
ydotool click 0x80
sleep 2.0
# park the cursor off the strip so hover-shrink is not in the picture
mv2 960 900; sleep 1.2
grim -o $MON $OUT/$TAG-2-afterdrop.png
hyprctl clients -j > $OUT/$TAG-clients.json

# the user's workaround: close and reopen
ov off; sleep 1.5
ov on;  sleep 3
grim -o $MON $OUT/$TAG-3-reopened.png
ov off; sleep 1
echo E8F_PROBE_OK
