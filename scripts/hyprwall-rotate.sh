#!/usr/bin/env bash
# Rotate the quickshell wallpaper. Writes background.wallpaperPath and lets
# quickshell's file watch pick it up (verified: 76% of pixels change ~4s later).
#
# Deliberately NOT switchwall.sh: that runs matugen + a python venv + kde
# -material-you and re-derives the Material palette, which drives
# general:col.active_border -- the exact value X2/X3/X4 measure against. A
# wallpaper rotation must not move the goalposts of the test suite. Verified
# 2026-08-02: a rotation leaves col.active_border and material_colors.scss
# byte-identical, so quickshell does not re-theme on its own either.
#
# Driven by a systemd user timer in the guest (hyprwall.timer, OnUnitActiveSec
# =3min). x1_fixture.sh stops it for the duration of a stress run.
set -u
DIR=${DIR:-/mnt/host/wallpapers}
CFG=$HOME/.config/illogical-impulse/config.json
[ -d "$DIR" ] || exit 0

CUR=$(jq -r '.background.wallpaperPath' "$CFG")

# A live wallpaper is a video path plus an mpvpaper process, and rotating a
# still image over it would kill the wallpaper every 3 minutes. Stand down and
# leave it alone -- switching back to stills is what turns the slideshow on.
case "${CUR,,}" in
    *.mp4|*.webm|*.mkv|*.avi|*.mov) exit 0 ;;
esac
pgrep -x mpvpaper >/dev/null && exit 0

NEXT=$(find "$DIR" -maxdepth 1 -name '*.jpg' ! -wholename "$CUR" | shuf -n1)
[ -n "$NEXT" ] || exit 0

jq --arg p "$NEXT" '.background.wallpaperPath = $p' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
echo "wallpaper -> $NEXT"
