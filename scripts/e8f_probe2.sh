#!/usr/bin/env bash
# E8-f probe 2: TWO drags in ONE overview session. The first drop onto the
# trailing desktop causes a NEW trailing desktop to be born; the second drop
# targets that one. Probe 1 showed the first drop renders fine, so the suspect
# is the workspace created after the last rebuild.
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/e8f; mkdir -p $OUT
TAG=${TAG:-q}
MON=$(hyprctl monitors -j | python3 -c "
import json,sys
print(next((m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')), ''))")

ov()  { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }
mv2() { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; }
walk(){ local n=14 i jx jy; for i in $(seq 1 $n); do
    jx=$(( (i % 3) * 8 - 8 )); jy=$(( (i % 2) * 11 - 5 ))
    mv2 $(( $1 + ($3 - $1) * i / n + jx )) $(( $2 + ($4 - $2) * i / n + jy )); sleep 0.04; done; }
drag(){ # gx gy tx ty label
    mv2 $1 $2; sleep 0.5
    ydotool click 0x40; sleep 0.12
    walk $1 $2 $3 $4; sleep 0.4
    walk $3 $4 $3 $4; sleep 0.6
    ydotool click 0x80
    sleep 0.25; mv2 960 900; grim -o $MON $OUT/$TAG-$5-t0.png
    sleep 1.0;              grim -o $MON $OUT/$TAG-$5-t1.png
    sleep 2.0;              grim -o $MON $OUT/$TAG-$5-t3.png
    hyprctl clients -j > $OUT/$TAG-$5-clients.json
}

ov off; sleep 1.2
ov on;  sleep 3
grim -o $MON $OUT/$TAG-0-rest.png
drag "$1" "$2" "$3" "$4" A
drag "$5" "$6" "$7" "$8" B
grim -o $MON $OUT/$TAG-final-open.png
ov off; sleep 1.5
ov on;  sleep 3
grim -o $MON $OUT/$TAG-reopened.png
ov off; sleep 1

# The gate lives on the HOST: the guest has no PIL, so image analysis cannot
# run here. Copy it out and print the command.
cp ~/overview-cpp/scripts/e8f_gate.py /mnt/host/ 2>/dev/null
echo "GATE: run on the host -> python3 /home/dragos/hyprvm/share/e8f_gate.py $TAG"
echo E8F_PROBE2_OK
