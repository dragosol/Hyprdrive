#!/usr/bin/env bash
# Y3: does the X28 menu open on the PLAIN DESKTOP (no overview)?
#
# Verified BEHAVIOURALLY, with no instrumentation and no geometry prediction.
# While the menu is up it takes every pointer press -- a press that misses it is
# a dismissal, never a click on whatever is underneath. So:
#
#   right-click the dock icon, then left-click a WINDOW.
#     menu opened  -> that press is swallowed  -> focus does NOT change
#     menu absent  -> that press reaches the window -> focus changes
#
# Focus is readable over hyprctl, so this needs no menu row positions -- which
# also means it cannot be fooled by a mis-predicted row.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)

warp() { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) >/dev/null 2>&1; }
press() { # $1 x $2 y $3 button(0x40=L 0xC0=R)
    warp $1 $2; sleep 0.3
    ydotool click $3 >/dev/null 2>&1
    sleep 0.8
}
cfg()  { hyprctl eval "hl.config({plugin={scrolloverview={dock={$1}}}}) return 0" >/dev/null 2>&1; }
focused() { hyprctl activewindow -j | python3 -c "
import json,sys
print(json.load(sys.stdin).get('title','(none)'))" 2>/dev/null; }

restore(){ cfg "autohide=true, show_favorites=true, show_apps_button=true, show_trash=true"; systemctl --user start hyprwall.timer 2>/dev/null; }
trap restore EXIT
systemctl --user stop hyprwall.timer 2>/dev/null

hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[off]]))" >/dev/null 2>&1; sleep 1
pkill -x kitty 2>/dev/null; pkill -f nautilus >/dev/null 2>&1; sleep 1.5
cfg "autohide=false, show_favorites=false, show_apps_button=false, show_trash=false, show_mounts=false"
sleep 0.8

for t in TARGETWIN OTHERWIN; do
    setsid kitty -c NONE --class Y3A --title "$t" -o confirm_os_window_close=0 \
        --hold sh -c 'sleep infinity' >/dev/null 2>&1 </dev/null &
    sleep 2
done

read -r AX AY <<< "$(hyprctl clients -j | python3 /mnt/host/x47_cell.py Y3A)"
# A point inside a window, well away from the dock pill at the bottom.
read -r WX WY <<< "$(hyprctl clients -j | python3 -c "
import json,sys
w=[c for c in json.load(sys.stdin) if c['class']=='Y3A' and c['title']=='TARGETWIN'][0]
print(w['at'][0]+w['size'][0]//2, w['at'][1]+w['size'][1]//2)")"
echo "icon=$AX,$AY  window centre=$WX,$WY"

# Land focus somewhere else first so a swallowed click is distinguishable.
press $WX $WY 0x40
F0=$(focused); echo "focus after clicking TARGETWIN: $F0"

hyprctl dispatch focuswindow title:OTHERWIN >/dev/null 2>&1; sleep 0.8
F1=$(focused); echo "focus moved away to: $F1"

echo "== right-click the dock icon (no overview open) =="
press $AX $AY 0xC0
echo "== now left-click TARGETWIN; a live menu swallows this =="
press $WX $WY 0x40
F2=$(focused)
echo "focus after the click: $F2"

if [ "$F2" = "$F1" ]; then
    echo "RESULT: press SWALLOWED -> the menu was open on the desktop. Y3 PASS"
else
    echo "RESULT: focus moved to '$F2' -> nothing swallowed it. Y3 FAIL"
fi
# dismiss and prove the swallow was not permanent
press $AX $AY 0x40; sleep 0.5
press $WX $WY 0x40
echo "focus after dismiss + click: $(focused)  (should be TARGETWIN again)"
