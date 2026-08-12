#!/usr/bin/env bash
# Lay the shipped fragments down in ~/.config/hypr/hyprdrive/, keeping every
# raw-snippet block that is already there.
#
# This is the same call the settings app (Phase 11) makes for one fragment: the
# machine-owned half comes from the caller, the user-owned half is read back out
# of the file on disk and put straight back. So "reinstall the defaults" and
# "the settings app wrote a new value" are the same operation, and both preserve
# hand edits by construction rather than by remembering to.
#
#   scripts/install-fragments.sh            ~/.config/hypr/hyprdrive
#   scripts/install-fragments.sh DIR        somewhere else (testing)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST=${1:-$HOME/.config/hypr/hyprdrive}
SRC=$ROOT/config/hyprdrive

[ -d "$SRC" ] || { echo "install-fragments: no $SRC" >&2; exit 1; }
mkdir -p "$DEST"

for f in "$SRC"/*.lua; do
    python3 "$ROOT/scripts/fragment.py" write "$DEST/$(basename "$f")" < "$f"
done

echo "fragments installed in $DEST"
echo "sourced by ~/.config/hypr/hyprland.lua in filename order"
