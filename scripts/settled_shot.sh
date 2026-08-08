#!/usr/bin/env bash
# One settled-overview frame, wallpaper pinned so two runs are comparable.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
SRC=/mnt/host/x48; OUT=/mnt/host/fade; mkdir -p $OUT
MON=$(cat $SRC/mon)
TAG=${1:?usage: settled_shot.sh <tag>}
CFG=$HOME/.config/illogical-impulse/config.json

# ov() comes from lib/rig.sh (verbatim-equivalent to the old local one).

systemctl --user stop hyprwall.timer 2>/dev/null
PIN=$(find /mnt/host/wallpapers -maxdepth 1 -name '*.jpg' | sort | head -1)
[ -n "$PIN" ] && { jq --arg p "$PIN" '.background.wallpaperPath = $p' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"; sleep 3; }

ov off; sleep 2.0
grim -o "$MON" "$OUT/$TAG-desktop.png"
ov on;  sleep 3.0
grim -o "$MON" "$OUT/$TAG-settled.png"
ov off; sleep 1.0
echo "SHOT_OK $TAG"
