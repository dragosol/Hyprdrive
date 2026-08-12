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
# THEME=1 turns that off for one call, and only for one call. Phase 10's theme
# adoption pipeline begins at the palette, so a gate that wants to watch a
# wallpaper swap re-theme the desktop has to be allowed to move the goalposts on
# purpose; every other caller, including the timer, still must not. The matugen
# invocation is ii's own -- the arguments switchwall.sh builds, minus the venv,
# the kde bridge and the Gemini categoriser, none of which touch the palette.
#
# Driven by a systemd user timer in the guest (hyprwall.timer, OnUnitActiveSec
# =3min). x1_fixture.sh stops it for the duration of a stress run.
#
#   hyprwall-rotate.sh                 pick a random other wallpaper
#   WALL=/path/to.jpg hyprwall-rotate.sh   pick that one (gates: be deterministic)
#   THEME=1 hyprwall-rotate.sh         ...and re-derive the palette from it
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

NEXT=${WALL:-$(find "$DIR" -maxdepth 1 -name '*.jpg' ! -wholename "$CUR" | shuf -n1)}
[ -n "$NEXT" ] && [ -f "$NEXT" ] || exit 0

jq --arg p "$NEXT" '.background.wallpaperPath = $p' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
echo "wallpaper -> $NEXT"

if [ "${THEME:-0}" = 1 ]; then
    # ii's own colorgen arguments: scheme type out of its config, dark/light out
    # of the GNOME setting switchwall.sh itself writes.
    TYPE=$(jq -r '.appearance.palette.type // "scheme-tonal-spot"' "$CFG")
    case "$TYPE" in scheme-*) ;; *) TYPE=scheme-tonal-spot ;; esac
    MODE=dark
    [ "$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null)" = "'prefer-light'" ] && MODE=light
    matugen --source-color-index 0 image "$NEXT" --mode "$MODE" --type "$TYPE" >/dev/null || exit 1
    echo "palette -> $(jq -r .primary "${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/user/generated/colors.json")"
fi
