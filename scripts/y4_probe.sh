#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC 13.14 Y4: a plain click minimizes ALL of an app's windows,
# a second click restores them all, and only CTRL+click cycles.
#
# STATE, NOT PIXELS. "Is it minimized" is a workspace question, and Minimize
# parks stashed windows on `special:minimized` -- so hyprctl answers it exactly,
# with none of the render-rate trouble that defeated the pixel route here.
#
# The click HOLDS ~120ms and JITTERS, per the standing rule: a press and release
# in the same instant never crosses the drag threshold and so never exercises the
# path a real hand does (X16's lesson, which cost a whole fire).
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)

dsp()  { hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }
ov()   { dsp "hl.plugin.scrolloverview.overview([[$1]])"; }
warp() { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; }
cfg()  { hyprctl eval "hl.config({plugin={scrolloverview={dock={$1}}}}) return 0" >/dev/null 2>&1; }

# press, wobble, release -- a real hand moves between the two edges
click() {
    local x=$1 y=$2 mod=${3:-}
    warp $x $y; sleep 0.25
    [ -n "$mod" ] && ydotool key 29:1 2>/dev/null   # KEY_LEFTCTRL down
    ydotool click 0x40 2>/dev/null                  # left DOWN
    sleep 0.06; warp $((x+4)) $((y+3)); sleep 0.06
    ydotool click 0x80 2>/dev/null                  # left UP
    [ -n "$mod" ] && ydotool key 29:0 2>/dev/null
    sleep 1.2
}

state() {
    hyprctl clients -j | python3 -c "
import json,sys
ws={}
for c in json.load(sys.stdin):
    if c['class']!='Y4A': continue
    ws[c['title']]=c['workspace']['name']
stash=sum(1 for v in ws.values() if v=='special:minimized')
print(f'{stash}/{len(ws)} stashed  ' + ' '.join(f'{k}={v}' for k,v in sorted(ws.items())))"
}
focused() {
    hyprctl activewindow -j | python3 -c "
import json,sys
d=json.load(sys.stdin); print(d.get('title','(none)'))" 2>/dev/null
}

restore() {
    ov off
    cfg "autohide=true, show_favorites=true, show_apps_button=true, show_trash=true, show_mounts=false"
    systemctl --user start hyprwall.timer 2>/dev/null
}
trap restore EXIT
systemctl --user stop hyprwall.timer 2>/dev/null
systemd-run --user --on-active=30min systemctl --user start hyprwall.timer >/dev/null 2>&1

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5
cfg "autohide=false, show_favorites=false, show_apps_button=false, show_trash=false, show_mounts=false"
sleep 0.8

for t in ONE TWO THREE; do
    setsid kitty -c NONE --class Y4A --title "$t" -o background='#101820' \
        -o background_opacity=1.0 -o confirm_os_window_close=0 \
        --hold sh -c 'sleep infinity' >/dev/null 2>&1 </dev/null &
    sleep 1.8
done
N=$(hyprctl clients -j | python3 -c "
import json,sys
print(sum(1 for c in json.load(sys.stdin) if c['class']=='Y4A'))")
[ "$N" = "3" ] || { echo "ABORT: expected 3 Y4A windows, got $N"; exit 1; }

read -r AX AY <<< "$(hyprctl clients -j | python3 /mnt/host/x47_cell.py Y4A)"
echo "icon=$AX,$AY"

ov on; sleep 2.5
echo "BEFORE        $(state)"

echo "== plain click 1 (expect: ALL THREE stashed)"
click $AX $AY
echo "AFTER-CLICK1  $(state)"

# The dock is drawn by the overview pass, so the overview has to be up for the
# icon to exist at all. A click that minimized everything may have closed it.
hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[on]]))" >/dev/null 2>&1; sleep 1.5

echo "== plain click 2 (expect: ALL THREE back)"
click $AX $AY
echo "AFTER-CLICK2  $(state)"

hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[on]]))" >/dev/null 2>&1; sleep 1.5
F0=$(focused)
echo "== ctrl+click (expect: NOTHING stashed, focus moves)"
click $AX $AY ctrl
echo "AFTER-CTRL    $(state)"
F1=$(focused)
echo "focus: '$F0' -> '$F1'"
echo Y4_PROBE_OK
