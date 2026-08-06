#!/usr/bin/env bash
# Film an animation from INSIDE the guest.
#
# WHY A RECORDER AND NOT grim. One-shot grim returns whatever frame the output
# last produced, and this guest produces almost none while the host's viewer
# window is buried -- which is why 15 screenshots of a slowed minimize came back
# with 14 identical frames. wf-recorder holds a wlr-screencopy session open and
# asks for every frame, which keeps the compositor rendering. Same reason the
# a2.mp4 capture on 2026-07-30 worked when stills did not.
#
# Combined with anim_scale, one real second of recording is many frames of a
# deliberately slowed animation.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)

WHAT=${1:-minimize}
SCALE=${2:-10}
OUT=/mnt/host/film; mkdir -p $OUT
cfg(){ hyprctl eval "hl.config({plugin={scrolloverview={dock={$1}}}}) return 0" >/dev/null 2>&1; }
ov(){ hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }

hyprctl eval "hl.config({plugin={scrolloverview={anim_scale=$SCALE}}}) return 0" >/dev/null 2>&1
sleep 0.5
echo "anim_scale: $(hyprctl getoption plugin:scrolloverview:anim_scale|head -1)"
cfg "autohide=false"; sleep 0.5

pkill -x kitty 2>/dev/null; sleep 1
setsid kitty -c NONE --class FILM --title FILMWIN -o background='#20406a' -o background_opacity=1.0 \
  -o font_size=34 -o confirm_os_window_close=0 --hold sh -c 'yes "FILM TEST" | head -24' >/dev/null 2>&1 </dev/null &
sleep 3
ov on; sleep 2.5

rm -f $OUT/$WHAT.mp4
wf-recorder -f $OUT/$WHAT.mp4 -c libvpx-vp9 -r 30 >$OUT/$WHAT-wfr.log 2>&1 &
WFR=$!
sleep 2.5                      # let the recorder settle and prove it is pulling frames

case "$WHAT" in
  minimize)
    hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.minimize())" >/dev/null 2>&1
    sleep 7
    hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.minimize([[restore]]))" >/dev/null 2>&1
    sleep 7
    ;;
  overview)
    ov off; sleep 5; ov on; sleep 5
    ;;
esac

kill -INT $WFR 2>/dev/null; wait $WFR 2>/dev/null
sleep 1
hyprctl eval "hl.config({plugin={scrolloverview={anim_scale=1}}}) return 0" >/dev/null 2>&1
cfg "autohide=true"
ls -la $OUT/$WHAT.mp4 2>/dev/null | awk '{print "recorded:", $5, "bytes"}'
