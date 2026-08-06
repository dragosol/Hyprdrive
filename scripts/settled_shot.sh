#!/usr/bin/env bash
# One settled-overview frame, wallpaper pinned so two runs are comparable.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
SRC=/mnt/host/x48; OUT=/mnt/host/fade; mkdir -p $OUT
MON=$(cat $SRC/mon)
TAG=${1:?usage: settled_shot.sh <tag>}
CFG=$HOME/.config/illogical-impulse/config.json

ov() { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }

systemctl --user stop hyprwall.timer 2>/dev/null
PIN=$(find /mnt/host/wallpapers -maxdepth 1 -name '*.jpg' | sort | head -1)
[ -n "$PIN" ] && { jq --arg p "$PIN" '.background.wallpaperPath = $p' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"; sleep 3; }

ov off; sleep 2.0
grim -o "$MON" "$OUT/$TAG-desktop.png"
ov on;  sleep 3.0
grim -o "$MON" "$OUT/$TAG-settled.png"
ov off; sleep 1.0
echo "SHOT_OK $TAG"
