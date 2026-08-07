#!/usr/bin/env bash
# Z3 (user report, 2026-08-07): "when I use the desktop strip to move windows to
# another desktop, the first move remembers the window's coordinates, but
# subsequent moves of that same window do not remember coordinates".
#
# The fixture exists to make "remembered" MEASURABLE, which means the window
# must not start anywhere a lost coordinate could land by accident. It is
# therefore parked at 200,150 -- hard against the top-left, nowhere near the
# workspace centre that centerBoxInWorkspace() would put it at, and nowhere near
# the spot every kitty spawns at (measured: two fixtures both arrive at
# 1055,586, which is exactly the stacking X42 set out to stop).
#
# One coloured marker per desktop, so the host can find each strip mini by the
# only window on it: yellow is ws2, cyan is ws3. MARK is red and is the one
# thing that moves.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/z3; mkdir -p $OUT

MARKX=200; MARKY=150

ov()  { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }
dsp() { hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }

systemctl --user stop hyprwall.timer 2>/dev/null
systemd-run --user --on-active=30min systemctl --user start hyprwall.timer >/dev/null 2>&1

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
hyprctl eval "return hl.monitor({output = [[$MON]], mode = [[2560x1600@60]], position = [[0x0]], scale = 1})" >/dev/null 2>&1; sleep 1.2
hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = true})" >/dev/null 2>&1; sleep 1.5
echo "output: $MON"

spawn() { # class colour ws w h
    dsp "hl.dsp.focus({monitor = \"$MON\"})"; sleep 0.15
    dsp "hl.dsp.focus({workspace = $3})"; sleep 0.25
    setsid kitty -c NONE --class "$1" -o background="$2" -o background_opacity=1.0 \
        -o confirm_os_window_close=0 --hold sh -c 'clear; sleep infinity' >/dev/null 2>&1 </dev/null &
    sleep 2.4
    A=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='$1'), ''))")
    [ -n "$A" ] || { echo "ABORT: $1 did not appear"; exit 1; }
    dsp "hl.dsp.focus({window = [[address:$A]]})"; sleep 0.3
    F=$(hyprctl activewindow -j | python3 -c "import json,sys;print(json.load(sys.stdin).get('floating'))")
    [ "$F" = "True" ] || { dsp "hl.dsp.window.float()"; sleep 0.5; }
    dsp "hl.dsp.window.resize({exact=true,x=$4,y=$5})"; sleep 0.6
}

spawn MARK '#ff0000' 1 1100 700
spawn Z3Y  '#ffff00' 2 700 450
spawn Z3C  '#00ffff' 3 700 450

# MARK to its corner LAST, so nothing else's layout pass moves it back.
dsp "hl.dsp.focus({workspace = 1})"; sleep 1.0
A=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='MARK'), ''))")
dsp "hl.dsp.focus({window = [[address:$A]]})"; sleep 0.4
dsp "hl.dsp.window.move({x=$MARKX,y=$MARKY,exact=true})"; sleep 0.8

AT=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((str(c['at']) for c in json.load(sys.stdin) if c['class']=='MARK'), '?'))")
echo "MARK parked at $AT (wanted [$MARKX, $MARKY])"
case "$AT" in "[$MARKX, $MARKY]") ;; *) echo "ABORT: MARK is at $AT"; exit 1 ;; esac

hyprctl clients -j > $OUT/clients-0.json
ov off; sleep 1.2
ov on;  sleep 3
grim -o $MON $OUT/view-ws1.png
echo Z3_SETUP_OK
