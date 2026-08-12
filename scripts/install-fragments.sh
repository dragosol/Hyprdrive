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

# The settings app's own fragments, one per pane. They are seeded EMPTY rather
# than created on first write, so that the pane's raw-snippet editor has a file
# to point at before anybody has changed a value -- and so `ls` on this directory
# tells you what the app owns. Each carries only its markers until a value lands.
python3 - "$ROOT" "$DEST" <<'PY'
import json, pathlib, subprocess, sys
root, dest = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
schema = json.loads((root / "docs" / "schema.json").read_text())
sys.path.insert(0, str(root / "scripts"))
for p in schema["panes"] + [{"id": "monitors", "fragment": "45-monitors.lua"}]:
    frag = p.get("fragment")
    if not frag or (dest / frag).exists():
        continue
    body = ("-- hyprdrive fragment %s -- the %s pane of the settings app.\n"
            "--\n-- Empty until the app writes a value here. Hand edits go BELOW the marker.\n"
            % (frag[:-4], p.get("title", p["id"])))
    subprocess.run([sys.executable, str(root / "scripts" / "fragment.py"), "write", str(dest / frag)],
                   input=body, text=True, check=True, capture_output=True)
    print("seeded %s" % (dest / frag))
PY

echo "fragments installed in $DEST"
echo "sourced by ~/.config/hypr/hyprland.lua in filename order"

if [ $# -gt 0 ]; then
    echo "theme-sync units and the settings app skipped (explicit DEST)"
    exit 0
fi

# ------------------------------------------------------- the settings app --
# Phase 11. The app is QML hosted by quickshell, installed ALONGSIDE
# illogical-impulse's own settings window and importing its widgets -- which is
# what "extends ii's settings shell" means in practice, and why the files land in
# ii's config directory rather than a config root of their own. The names are
# distinct (hyprdrive-settings.qml, modules/hyprdrive/) so an ii update cannot
# collide with them and this install cannot clobber ii.
QS_CONFIG=${HYPRDRIVE_QS_CONFIG:-$HOME/.config/quickshell/ii}
BIN=$HOME/.local/bin
APPS=$HOME/.local/share/applications

if [ -d "$QS_CONFIG" ]; then
    install -Dm644 "$ROOT/config/quickshell/hyprdrive-settings.qml" "$QS_CONFIG/hyprdrive-settings.qml"
    mkdir -p "$QS_CONFIG/modules/hyprdrive"
    install -m644 -t "$QS_CONFIG/modules/hyprdrive" "$ROOT"/config/quickshell/modules/hyprdrive/*.qml
    echo "settings app installed in $QS_CONFIG"
else
    echo "settings app NOT installed: no quickshell config at $QS_CONFIG" >&2
fi

install -Dm755 "$ROOT/config/hyprdrive-settings" "$BIN/hyprdrive-settings"
mkdir -p "$APPS"
sed "s|^Exec=hyprdrive-settings|Exec=$BIN/hyprdrive-settings|" \
    "$ROOT/config/hyprdrive-settings.desktop" > "$APPS/hyprdrive-settings.desktop.tmp"
mv "$APPS/hyprdrive-settings.desktop.tmp" "$APPS/hyprdrive-settings.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" 2>/dev/null || true
echo "launcher: $BIN/hyprdrive-settings   desktop entry: $APPS/hyprdrive-settings.desktop"

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

# --------------------------------------------------------------- slideshow --
# Phase 12. The unit is laid down but NOT enabled: whether a slideshow runs is a
# setting (wallpaper.mode), and `hdwall slideshow` is the one thing that reads
# that setting and starts or stops the timer accordingly. Enabling it here would
# be the installer overriding a preference it has not read.
if [ -f "$UNITS/hyprdrive-slideshow.timer" ] && command -v systemctl >/dev/null 2>&1; then
    mkdir -p "$SYSTEMD_DEST"
    sed "s|@REPO@|$ROOT|g" "$UNITS/hyprdrive-slideshow.service" > "$SYSTEMD_DEST/hyprdrive-slideshow.service"
    cp "$UNITS/hyprdrive-slideshow.timer" "$SYSTEMD_DEST/hyprdrive-slideshow.timer"
    systemctl --user daemon-reload
    python3 "$ROOT/scripts/hdwall.py" slideshow
fi

# ---------------------------------------------------------------- profiles --
# Phase 12. The snapshot repository has to exist BEFORE the first import or bulk
# apply, because the whole promise is that those happen behind one -- and a
# repository created by the first thing that needs it has no record of what the
# system looked like before that thing ran. Idempotent: a second install just
# says where it already is.
python3 "$ROOT/scripts/hdprof.py" init
