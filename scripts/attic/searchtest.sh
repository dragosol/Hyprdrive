#!/usr/bin/env bash
# Does a typed query filter the overview AT ALL? No minimize involved, so this
# isolates the search from Y9's gate: two visible fixtures, type a query that
# matches exactly one. If the other does not vanish, typing is not reaching the
# search bar and Y9's "filter brings it back" cannot possibly work either.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
OUT=/mnt/host/film; mkdir -p $OUT
ov(){ hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }
ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.2
setsid kitty -c NONE --class STGREEN --title GREENWIN -o background='#106030' -o background_opacity=1.0 \
  -o font_size=40 -o confirm_os_window_close=0 --hold sh -c 'yes "GREEN" | head -24' >/dev/null 2>&1 </dev/null & sleep 2.5
setsid kitty -c NONE --class STRED --title REDWIN -o background='#901020' -o background_opacity=1.0 \
  -o font_size=40 -o confirm_os_window_close=0 --hold sh -c 'yes "RED" | head -24' >/dev/null 2>&1 </dev/null & sleep 2.5
rm -f $OUT/search.mp4
wf-recorder -f $OUT/search.mp4 -c libvpx-vp9 -r 30 >/dev/null 2>&1 &
W=$!
sleep 2
ov on; sleep 4          # t~2-6: overview, no query, BOTH visible
ydotool type "REDWIN" >/dev/null 2>&1
sleep 5                 # t~7-11: query typed, only RED should survive
kill -INT $W 2>/dev/null; wait $W 2>/dev/null
ov off
echo "recorded $(stat -c%s $OUT/search.mp4) bytes"
