#!/usr/bin/env bash
# Global animation slowdown, then watch a minimize one frame at a time.
# At anim_scale=20 the 400ms flight lasts 8s, so even this guest's poor capture
# rate gets a dozen frames of it -- which is the whole point of the slider.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
SCALE=${1:-20}
OUT=/mnt/host/slowmo; mkdir -p $OUT; rm -f $OUT/*.png
cfg(){ hyprctl eval "hl.config({plugin={scrolloverview={dock={$1}}}}) return 0" >/dev/null 2>&1; }
hyprctl eval "hl.config({plugin={scrolloverview={anim_scale=$SCALE}}}) return 0" >/dev/null 2>&1
sleep 0.6
echo "anim_scale readback: $(hyprctl getoption plugin:scrolloverview:anim_scale | head -1)"
cfg "autohide=false"; sleep 0.5
pkill -x kitty 2>/dev/null; sleep 1
setsid kitty -c NONE --class SLOW --title SLOWWIN -o background='#203040' -o background_opacity=1.0 \
  -o font_size=30 -o confirm_os_window_close=0 --hold sh -c 'yes "SLOWMOTION TEST WINDOW" | head -30' >/dev/null 2>&1 </dev/null &
sleep 3
hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[on]]))" >/dev/null 2>&1; sleep 2.5
grim "$OUT/00_before.png" 2>/dev/null
hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.minimize())" >/dev/null 2>&1
for i in $(seq 1 14); do
    grim "$OUT/$(printf %02d $i)_fly.png" 2>/dev/null
    sleep 0.55
done
grim "$OUT/99_after.png" 2>/dev/null
echo "frames: $(ls $OUT/*.png | wc -l)"
hyprctl eval "hl.config({plugin={scrolloverview={anim_scale=1}}}) return 0" >/dev/null 2>&1
cfg "autohide=true"
