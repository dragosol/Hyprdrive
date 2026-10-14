#!/usr/bin/env bash
# Install Hyprdrive: the .so, the Lua fragments and their loader, a require()
# from ~/.config/hypr/hyprland.lua -- and, ON OMARCHY ONLY, the settings panel.
#
# One script for both desktops (native port P0-3). Which one this is comes from
# scripts/hyprdrive-integration (Integration.hpp's rule: HYPRDRIVE_NO_OMARCHY /
# HYPRDRIVE_INTEGRATION, else `omarchy` on PATH and its state dir). On plain
# Hyprland nothing under ~/.config/omarchy is created or touched.
#
# Appearance is not installed. The plugin reads Hyprland's live theme values
# (borders, rounding, blur, shadows); Omarchy already writes those on
# `omarchy theme set` and reloads the compositor.
#
#   scripts/install-fragments.sh            live install (`make install` runs this)
#   scripts/install-fragments.sh DIR        fragments only, for tests
#
# Env: PREFIX (default ~/.local) -- the .so goes to $PREFIX/lib/hyprdrive and the
# hyprdrive-integration CLI to $PREFIX/bin; 00-plugin.lua is written with that
# PREFIX so the loader finds the .so wherever it went.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=${PREFIX:-$HOME/.local}
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}
DEST=${1:-$CONFIG/hypr/hyprdrive}
SRC=$ROOT/config/hyprdrive
LOADER_SRC=$ROOT/config/hyprdrive.lua
LOADER_DEST=$CONFIG/hypr/hyprdrive.lua
HYPRLAND_LUA=$CONFIG/hypr/hyprland.lua
HYPRLAND_CONF=$CONFIG/hypr/hyprland.conf
LIBDIR=$PREFIX/lib/hyprdrive
INTEGRATION_CLI=$ROOT/scripts/hyprdrive-integration

[ -d "$SRC" ] || { echo "install-fragments: no $SRC" >&2; exit 1; }
case $PREFIX in
    /*) ;;
    *) echo "install-fragments: PREFIX must be absolute (got $PREFIX)" >&2; exit 1 ;;
esac

# omarchy | none, and why -- printed, because "why did it (not) install the
# panel" is the first question anyone will have.
INTEGRATION=$(sh "$INTEGRATION_CLI" --why) || INTEGRATION=none
DESKTOP=$(printf '%s\n' "$INTEGRATION" | sed -n 1p)
echo "integration: $DESKTOP ($(printf '%s\n' "$INTEGRATION" | sed -n 's/^reason: //p'))"

mkdir -p "$DEST"

for f in "$SRC"/*.lua; do
    # @HYPRDRIVE_PREFIX@ -> PREFIX (00-plugin.lua's .so search). Python, not
    # sed: a PREFIX with | or & in it is a path, not a sed expression.
    python3 -c 'import sys; sys.stdout.write(sys.stdin.read().replace("@HYPRDRIVE_PREFIX@", sys.argv[1]))' "$PREFIX" < "$f" \
        | python3 "$ROOT/scripts/fragment.py" write "$DEST/$(basename "$f")"
done

echo "fragments installed in $DEST"

if [ $# -gt 0 ]; then
    echo "loader, plugin copy, and hyprland.lua skipped (explicit DEST)"
    exit 0
fi

install -Dm644 "$LOADER_SRC" "$LOADER_DEST"
echo "loader: $LOADER_DEST"

# The require line. Omarchy puts ~/.config on package.path, so its configs say
# require("hypr.hyprdrive") and that is what an Omarchy install keeps writing.
# Plain Hyprland only has the config dir itself (~/.config/hypr/?.lua), where
# the same file is require("hyprdrive"). Either existing spelling counts as
# present: requiring the loader twice under two module names would run every
# fragment twice.
if [ -f "$HYPRLAND_LUA" ]; then
    if grep -Eq "^[[:space:]]*require[[:space:]]*\\(?[[:space:]]*[\"'](hypr\\.)?hyprdrive[\"']" "$HYPRLAND_LUA"; then
        echo "hyprland.lua already requires the hyprdrive loader"
    else
        if [ "$DESKTOP" = omarchy ]; then MODULE=hypr.hyprdrive; else MODULE=hyprdrive; fi
        printf '\n-- Hyprdrive (overview + dock). Fragments live in hypr/hyprdrive/.\nrequire("%s")\n' "$MODULE" >> "$HYPRLAND_LUA"
        echo "added require(\"$MODULE\") to $HYPRLAND_LUA"
    fi
elif [ -f "$HYPRLAND_CONF" ]; then
    # HYPRLANG USERS. Hyprland 0.56 reads hyprland.lua when it exists and
    # hyprland.conf only when it does not, so creating a hyprland.lua here
    # would silently swap out the user's whole config. Say what works instead.
    cat >&2 <<EOF
install-fragments: $HYPRLAND_CONF is a hyprlang config, and Hyprdrive's
fragments (overview submap, 3-finger gestures, settings) are Lua. They are
installed in $DEST but nothing loads them. Two honest options:
  * stay on hyprland.conf: add
        plugin = $LIBDIR/hyprdrive.so
    The plugin loads; tapping SUPER opens the overview and the dock works.
    The fragments' binds and gestures do not exist -- bind the dispatchers
    yourself, e.g.  bind = SUPER, TAB, hyprdrive:overview, toggle all
  * move to Lua (Hyprland 0.56's hyprland.lua) and add
        require("hyprdrive")
    at the end; then re-run make install.
EOF
else
    echo "install-fragments: no $HYPRLAND_LUA -- add at its end: require(\"hyprdrive\")" >&2
fi

if [ -f "$ROOT/hyprdrive.so" ]; then
    install -Dm755 "$ROOT/hyprdrive.so" "$LIBDIR/hyprdrive.so"
    echo "plugin: $LIBDIR/hyprdrive.so"
else
    echo "install-fragments: no hyprdrive.so -- run make all first, then re-run this" >&2
fi

install -Dm755 "$INTEGRATION_CLI" "$PREFIX/bin/hyprdrive-integration"
echo "cli: $PREFIX/bin/hyprdrive-integration"

PLUGIN_SRC=$ROOT/omarchy-plugin
PLUGIN_DEST=$CONFIG/omarchy/plugins/dragos.hyprdrive
# THE PANEL IS AN OMARCHY SHELL PLUGIN: it imports qs.Commons/qs.Ui from the
# Omarchy shell and cannot run anywhere else (audit B1). Off Omarchy it is not
# copied, and -- the point -- ~/.config/omarchy is never created: an empty
# omarchy tree in a plain home is exactly the half-signal that makes other
# tools (and the old detection) think Omarchy is there.
if [ "$DESKTOP" != omarchy ]; then
    echo "omarchy plugin: skipped (integration: $DESKTOP)"
    exit 0
fi

# INSTALLED FROM THE MARKETPLACE: `omarchy plugin add` cloned this very
# repository into $PLUGIN_DEST, and its root manifest.json points the shell at
# omarchy-plugin/Panel.qml. The panel is already installed -- it IS this
# checkout -- and copying omarchy-plugin/ over the clone's root would dirty it
# and break `omarchy plugin update`.
if [ -d "$PLUGIN_DEST" ] && [ "$(cd "$PLUGIN_DEST" && pwd -P)" = "$(cd "$ROOT" && pwd -P)" ]; then
    echo "omarchy plugin: $PLUGIN_DEST is this checkout (marketplace install) -- panel already in place"
elif [ -d "$PLUGIN_SRC" ]; then
    # The Omarchy shell watches this directory with inotify and re-initialises
    # EVERY installed plugin whenever a loadable source (manifest.json, *.qml,
    # *.js) is written. Three of the files below are loadable, and they land
    # within ~2ms of each other, well inside the shell's 150ms reload debounce
    # -- so the shell reloads against a half-copied plugin, and that reload
    # spawns ~500 processes (measured). Pause the watcher across the copy and
    # fire exactly one reload once everything is in place.
    # See omacom/omarchy#12601 and #11923.
    RELOAD_PAUSE=$(command -v omarchy-plugin-reload-pause || true)
    if [ -n "$RELOAD_PAUSE" ]; then
        "$RELOAD_PAUSE" on >/dev/null
        trap '"$RELOAD_PAUSE" off >/dev/null 2>&1 || true' EXIT INT TERM
    fi

    mkdir -p "$PLUGIN_DEST/bin"
    # ONE MANIFEST: the marketplace refuses a repository with a second
    # manifest.json near the top, so the copied panel's is generated from the
    # root one, with the entry point moved to where Panel.qml lands here.
    python3 - "$ROOT/manifest.json" "$PLUGIN_DEST/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m["entryPoints"] = {k: v.split("/")[-1] for k, v in m.get("entryPoints", {}).items()}
open(sys.argv[2], "w").write(json.dumps(m, indent=2, ensure_ascii=False) + "\n")
PY
    install -Dm644 "$PLUGIN_SRC/Panel.qml" "$PLUGIN_DEST/Panel.qml"
    install -Dm644 "$PLUGIN_SRC/HyprdrivePanel.qml" "$PLUGIN_DEST/HyprdrivePanel.qml"
    install -Dm644 "$PLUGIN_SRC/Schema.js" "$PLUGIN_DEST/Schema.js"
    install -Dm644 "$PLUGIN_SRC/Model.js" "$PLUGIN_DEST/Model.js"
    install -Dm644 "$PLUGIN_SRC/README.md" "$PLUGIN_DEST/README.md"
    install -Dm644 "$PLUGIN_SRC/hyprdrive-icon.png" "$PLUGIN_DEST/hyprdrive-icon.png"
    install -Dm755 "$PLUGIN_SRC/bin/hdpanel" "$PLUGIN_DEST/bin/hdpanel"
    install -Dm755 "$PLUGIN_SRC/bin/hdicons" "$PLUGIN_DEST/bin/hdicons"
    # Super+L's layout cycle while the panel's Mosaic switch is on; 40-panel.lua
    # binds it by this path (hdpanel's LAYOUT_CYCLE, beside hdpanel itself).
    install -Dm755 "$PLUGIN_SRC/bin/hd-layout-cycle" "$PLUGIN_DEST/bin/hd-layout-cycle"
    echo "omarchy plugin: $PLUGIN_DEST"

    if [ -n "$RELOAD_PAUSE" ]; then
        "$RELOAD_PAUSE" off >/dev/null
        trap - EXIT INT TERM
        # Everything is on disk now: one deliberate reload instead of a
        # mid-copy one. Skipped if the shell is not running.
        if pgrep -x quickshell >/dev/null 2>&1; then
            touch "$PLUGIN_DEST/manifest.json"
            echo "shell reload: 1 (watcher paused during copy)"
        fi
    fi
fi
