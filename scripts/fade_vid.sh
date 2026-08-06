#!/usr/bin/env bash
# Chrome fade A/B, VIDEO version. Runs IN THE GUEST on the x48 fixture; the
# host extracts frames with ffmpeg and grades with fade_gate.py.
#
# WHY VIDEO. The open is ~260ms and a full-screen grim in this guest costs
# ~175ms, so a burst resolves one or two frames and their phase is whatever the
# scheduler gives. The plugin's speed knobs cannot be turned down for the
# camera either: 0.56's Lua parser rejects the plugin's Hyprlang keys ("unknown
# config key 'plugin.scrolloverview.open_speed'"). wf-recorder samples the same
# animation at video rate, and as a bonus it keeps ASKING the headless output
# for frames, which is what stops it idling at ~1fps.
#
# Gesture order, one recording: open, settle, close, then open + toggle OFF
# 100ms in -- the user's "toggle overview off halfway through".
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
SRC=/mnt/host/x48; OUT=/mnt/host/fade; mkdir -p $OUT
MON=$(cat $SRC/mon)
TAG=${1:?usage: fade_vid.sh <tag>}
CFG=$HOME/.config/illogical-impulse/config.json

ov() { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }

systemctl --user stop hyprwall.timer 2>/dev/null

# PIN the wallpaper: presence is measured against the desktop, so two runs on
# two backdrops are not comparable. Measured 2026-08-06: a rotated wallpaper
# moved settled presence by 18 points, larger than the effect being graded.
PIN=$(find /mnt/host/wallpapers -maxdepth 1 -name '*.jpg' | sort | head -1)
if [ -n "$PIN" ]; then
    jq --arg p "$PIN" '.background.wallpaperPath = $p' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    sleep 3
fi
echo "wallpaper: $(jq -r '.background.wallpaperPath' "$CFG")"

ov off; sleep 2.0

rm -f "$OUT/$TAG.mp4"
wf-recorder -o "$MON" -f "$OUT/$TAG.mp4" -r 60 >/dev/null 2>&1 &
REC=$!
sleep 3.0                 # let the encoder settle; these frames are the desktop

ov on;  sleep 3.0         # OPEN, then settled
ov off; sleep 3.0         # closed again

ov on; sleep 0.10; ov off # REVERSE: toggled off mid-flight
sleep 3.0

kill -INT $REC 2>/dev/null
wait $REC 2>/dev/null
sleep 1
systemctl --user start hyprwall.timer 2>/dev/null
ls -la "$OUT/$TAG.mp4"
echo FADE_VID_OK
