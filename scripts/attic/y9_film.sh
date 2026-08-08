#!/usr/bin/env bash
# Y9: is a MINIMIZED window visible in the overview grid?
# Filmed, because stills are stale on this guest. Two windows, one distinctive
# colour each; minimize one, then open the overview and record it.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/film; mkdir -p $OUT
ov(){ hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }
ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.2
# GREEN stays put, RED gets minimized. Distinct fills so the film can be read.
setsid kitty -c NONE --class Y9F --title GREENWIN -o background='#106030' -o background_opacity=1.0 \
  -o font_size=40 -o confirm_os_window_close=0 --hold sh -c 'yes "GREEN GREEN GREEN" | head -24' >/dev/null 2>&1 </dev/null & sleep 2.5
setsid kitty -c NONE --class Y9F --title REDWIN -o background='#901020' -o background_opacity=1.0 \
  -o font_size=40 -o confirm_os_window_close=0 --hold sh -c 'yes "RED RED RED RED" | head -24' >/dev/null 2>&1 </dev/null & sleep 2.5
hyprctl dispatch focuswindow title:REDWIN >/dev/null 2>&1; sleep 0.8
hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.minimize())" >/dev/null 2>&1; sleep 1.5
echo "stashed: $(hyprctl clients -j | python3 -c "
import json,sys
print([(c[\"title\"],c[\"workspace\"][\"name\"]) for c in json.load(sys.stdin) if c[\"class\"]==\"Y9F\"])")"
rm -f $OUT/y9.mp4
wf-recorder -f $OUT/y9.mp4 -c libvpx-vp9 -r 30 >/dev/null 2>&1 &
W=$!
sleep 2
ov on; sleep 5
kill -INT $W 2>/dev/null; wait $W 2>/dev/null
ov off
echo "recorded $(stat -c%s $OUT/y9.mp4 2>/dev/null) bytes"
