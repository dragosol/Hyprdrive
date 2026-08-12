#!/usr/bin/env bash
# Lay the shipped fragments down in ~/.config/hypr/hyprdrive/, keeping every
# raw-snippet block that is already there, and install the theme-adoption
# pipeline that keeps the derived fragment in step with the wallpaper.
#
# This is the same call the settings app (Phase 11) makes for one fragment: the
# machine-owned half comes from the caller, the user-owned half is read back out
# of the file on disk and put straight back. So "reinstall the defaults" and
# "the settings app wrote a new value" are the same operation, and both preserve
# hand edits by construction rather than by remembering to.
#
#   scripts/install-fragments.sh            ~/.config/hypr/hyprdrive
#   scripts/install-fragments.sh DIR        somewhere else (testing)
#
# With a DIR argument the systemd half is skipped: a test install must not
# re-point the live session's theme pipeline at a scratch directory.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST=${1:-$HOME/.config/hypr/hyprdrive}
SRC=$ROOT/config/hyprdrive
UNITS=$ROOT/config/systemd
SYSTEMD_DEST=$HOME/.config/systemd/user

[ -d "$SRC" ] || { echo "install-fragments: no $SRC" >&2; exit 1; }
mkdir -p "$DEST"

for f in "$SRC"/*.lua; do
    python3 "$ROOT/scripts/fragment.py" write "$DEST/$(basename "$f")" < "$f"
done

# The derived fragment is GENERATED, not copied: config/hyprdrive/ holds what a
# human chooses and this one is machine-derived from the palette. Copying a
# stale 05-theme-derived.lua out of the repo would overwrite a live theme with
# whatever colours the last committer's wallpaper happened to have.
python3 "$ROOT/scripts/theme-sync.py" --dest "$DEST" --no-apply

echo "fragments installed in $DEST"
echo "sourced by ~/.config/hypr/hyprland.lua in filename order"

if [ $# -gt 0 ]; then
    echo "theme-sync units skipped (explicit DEST)"
    exit 0
fi

# ------------------------------------------------------------- theme-sync --
# Phase 10. matugen writes the palette, the path unit notices, theme-sync
# re-derives 05-theme-derived.lua and reloads. No daemon, no polling, and
# nothing for the user to run after changing a wallpaper.
if [ -d "$UNITS" ] && command -v systemctl >/dev/null 2>&1; then
    mkdir -p "$SYSTEMD_DEST"
    sed "s|@REPO@|$ROOT|g" "$UNITS/hyprdrive-theme-sync.service" > "$SYSTEMD_DEST/hyprdrive-theme-sync.service"
    cp "$UNITS/hyprdrive-theme-sync.path" "$SYSTEMD_DEST/hyprdrive-theme-sync.path"
    systemctl --user daemon-reload
    systemctl --user enable --now hyprdrive-theme-sync.path
    echo "theme-sync watching $(sed -n 's/^PathChanged=//p' "$UNITS/hyprdrive-theme-sync.path")"
else
    echo "theme-sync units NOT installed (no $UNITS or no systemctl)" >&2
fi
