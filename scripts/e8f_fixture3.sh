#!/usr/bin/env bash
# E8-f fixture 3: TILED windows. The X41 fixture forces every window floating,
# which makes endWindowDrag() take the non-RETILEONEND branch -- so the
# moveWindowToWorkspace() + changeWorkspace() path a real (tiled) drop uses was
# never exercised. Same family as bestScale being pinned at 1.0.
# kitty, never foot (user standing rule).
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/e8f; mkdir -p $OUT

ov() { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }
dsp() { hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }

systemctl --user stop hyprwall.timer 2>/dev/null
ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5

hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = false})" >/dev/null 2>&1; sleep 1.2
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
hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = true})" >/dev/null 2>&1; sleep 1.5
echo "output: $MON"

spawn() { # class colour ws
    dsp "hl.dsp.focus({monitor = \"$MON\"})"; sleep 0.15
    dsp "hl.dsp.focus({workspace = $3})"; sleep 0.2
    setsid kitty -c NONE --class "$1" -o background="$2" -o background_opacity=1.0 \
        -o confirm_os_window_close=0 --hold sh -c 'clear' >/dev/null 2>&1 </dev/null &
    sleep 2.2
    A=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='$1'), ''))")
    [ -n "$A" ] || { echo "ABORT: $1 did not appear"; exit 1; }
}

spawn MARK  '#ff0000' 1
spawn E8G    '#00ff00' 1
spawn E8Y    '#ffff00' 2

dsp 'hl.dsp.focus({workspace = 1})'; sleep 1.5
hyprctl clients -j > $OUT/f3-clients.json
python3 - <<'EOF'
import json
for c in json.load(open('/mnt/host/e8f/f3-clients.json')):
    if c['class'] in ('MARK','E8G','E8Y'):
        print('%-5s ws=%-3s float=%-5s at=%s size=%s' % (c['class'], c['workspace']['id'], c['floating'], c['at'], c['size']))
EOF
ov off; sleep 1.2
ov on;  sleep 3
grim -o $MON $OUT/f3-rest.png
ov off; sleep 1
echo E8F_FIXTURE3_OK
