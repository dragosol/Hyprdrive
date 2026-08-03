#!/bin/bash
# X29 dock frost. Runs IN THE GUEST; the fit is on the HOST.
#   x29_capture.sh <size> <passes>   (repeatable, no rebuild)
#
# Fitting a blur needs STRUCTURE under it. A first attempt sampled the pill over
# whatever wallpaper happened to be there and the fit ran away to sigma 138: a
# smooth backdrop blurred by anything looks the same, so the search just picked
# the flattest candidate. Two tiled windows, black and white, put a hard edge
# straight through the pill and make the fit well-posed.
#
# The reference frame is the SAME screen with the dock switched off, which is
# possible at runtime because the plugin exposes hl.plugin.scrolloverview
# .configure -- `hyprctl keyword` is dead in 0.56 but this is not.
set -u
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t $XDG_RUNTIME_DIR/hypr | head -1)
OUT=/mnt/host/x29
SIZE=${1:-}; PASSES=${2:-}

cfg() { hyprctl eval "return hl.plugin.scrolloverview.configure($1)" >/dev/null; }

systemctl --user stop hyprwall.timer
hyprctl dispatch "hl.dsp.focus({workspace = 1})" >/dev/null

if ! pgrep -f x29fixL >/dev/null; then
    pkill kitty; sleep 1.5
    setsid -f kitty --class x29fixL --override background=#000000 sh -c 'sleep 3600' </dev/null >/dev/null 2>&1
    sleep 1.8
    setsid -f kitty --class x29fixR --override background=#ffffff sh -c 'sleep 3600' </dev/null >/dev/null 2>&1
    sleep 1.8
fi

cfg "{dock = {enabled = false}}"; sleep 1.0
grim -o Virtual-1 $OUT/nodock.png

# No args means "measure what the plugin ships", which is what the gate should be
# asserting; args are for sweeping.
if [ -n "$SIZE" ]; then
    cfg "{dock = {enabled = true, blur_size = $SIZE, blur_passes = $PASSES}}"
else
    cfg "{dock = {enabled = true}}"
fi
sleep 1.2
grim -o Virtual-1 $OUT/dock.png

# `unblur-in-overview` is false in the reference: the pill keeps its frost with
# the overview open. Same pair of frames, overview up.
ov() { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null; }
clear_search() { for _ in $(seq 20); do ydotool key 14:1 14:0; done; sleep 0.4; }

ov on; sleep 1.5
clear_search
cfg "{dock = {enabled = false}}"; sleep 1.2
grim -o Virtual-1 $OUT/nodock_ov.png
cfg "{dock = {enabled = true}}"; sleep 1.2
grim -o Virtual-1 $OUT/dock_ov.png
ov off; sleep 0.5

echo "size=${SIZE:-default} passes=${PASSES:-default}"
