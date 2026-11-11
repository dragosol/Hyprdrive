#!/usr/bin/env bash
# Install Hyprdrive: the .so, the Lua fragments and their loader, a require()
# from ~/.config/hypr/hyprland.lua -- and, ON OMARCHY ONLY, the settings panel.
#
# One script for both desktops (native port P0-3); off Omarchy the settings
# are the standalone app (settings/) instead of the panel (B1). Which one this
# is comes from
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
    # Same rule as the Makefile: the installed copy carries no debug information
    # unless KEEP_DEBUG is set. This copy is the last one written, so it is the
    # one that has to be stripped.
    if [ -z "${KEEP_DEBUG:-}" ] && command -v strip >/dev/null 2>&1; then
        strip --strip-debug "$LIBDIR/hyprdrive.so"
    fi
    echo "plugin: $LIBDIR/hyprdrive.so"
else
    echo "install-fragments: no hyprdrive.so -- run make all first, then re-run this" >&2
fi

install -Dm755 "$INTEGRATION_CLI" "$PREFIX/bin/hyprdrive-integration"
echo "cli: $PREFIX/bin/hyprdrive-integration"

# `hyprdrive update` (ui/bin/hyprdrive): on PATH, and beside hdpanel
# in lib/ where the settings app finds it. It reads what was installed, and from
# where, in install.json -- the version, this checkout, PREFIX.
install -Dm755 "$ROOT/ui/bin/hyprdrive" "$LIBDIR/hyprdrive"
rm -f "$PREFIX/bin/hyprdrive"
ln -s ../lib/hyprdrive/hyprdrive "$PREFIX/bin/hyprdrive"
python3 - "$ROOT" "$PREFIX" <<'PY'
import json, os, pathlib, sys
root, prefix = sys.argv[1:3]
state = pathlib.Path(os.environ.get("XDG_STATE_HOME") or pathlib.Path.home() / ".local/state") / "hyprdrive"
state.mkdir(parents=True, exist_ok=True)
version = json.loads((pathlib.Path(root) / "manifest.json").read_text()).get("version", "")
tmp = state / "install.json.tmp"
tmp.write_text(json.dumps({"version": version, "source": root, "prefix": prefix}) + "\n")
tmp.replace(state / "install.json")
PY
echo "cli: $PREFIX/bin/hyprdrive (hyprdrive update)"

PLUGIN_SRC=$ROOT/ui
PLUGIN_DEST=$CONFIG/omarchy/plugins/dragos.hyprdrive
# THE PANEL IS AN OMARCHY SHELL PLUGIN: it imports qs.Commons/qs.Ui from the
# Omarchy shell and cannot run anywhere else (audit B1). Off Omarchy it is not
# copied, and -- the point -- ~/.config/omarchy is never created: an empty
# omarchy tree in a plain home is exactly the half-signal that makes other
# tools (and the old detection) think Omarchy is there.
#
# OFF OMARCHY THE SETTINGS ARE THE STANDALONE APP instead (settings/): the
# same Schema.js rows and hdpanel/hdicons back ends in a Quickshell window of
# its own. Quickshell refuses imports from outside the directory its root QML
# is in (they resolve to qrc:/qs-blackhole), so the panel's Schema.js, Model.js
# and mark go INTO that directory -- in the checkout as symlinks, here as
# copies (install follows the links):
#   $PREFIX/share/hyprdrive/settings/        shell.qml, SettingsPage.qml,
#                                            Schema.js, Model.js, the mark
#   $PREFIX/lib/hyprdrive/                   hdpanel, hdicons, hyprdrive-power-watch,
#                                            hd-layout-cycle (a link to the one in bin)
#   $PREFIX/bin/hyprdrive-layout-cycle       Super+L's layout cycle (A18); 40-panel.lua
#                                            binds it there while Mosaic is on
#   $PREFIX/bin/hyprdrive-settings           the launcher (one instance, deep links)
#   $PREFIX/share/applications/hyprdrive-settings.desktop
if [ "$DESKTOP" != omarchy ]; then
    echo "omarchy plugin: skipped (integration: $DESKTOP)"
    SHARE=$PREFIX/share/hyprdrive
    for f in shell.qml SettingsPage.qml Schema.js Model.js hyprdrive-icon.png; do
        install -Dm644 "$ROOT/ui/settings/$f" "$SHARE/settings/$f"
    done
    for f in hdpanel hdicons; do
        install -Dm755 "$PLUGIN_SRC/bin/$f" "$LIBDIR/$f"
    done
    # The layout cycle is a command of its own here (A18): on PATH, and what
    # hdpanel binds Super+L to. lib/ keeps a link under the old name, which a
    # 40-panel.lua written before this release binds by path.
    install -Dm755 "$PLUGIN_SRC/bin/hd-layout-cycle" "$PREFIX/bin/hyprdrive-layout-cycle"
    rm -f "$LIBDIR/hd-layout-cycle"
    ln -s ../../bin/hyprdrive-layout-cycle "$LIBDIR/hd-layout-cycle"
    echo "layout cycle: $PREFIX/bin/hyprdrive-layout-cycle"
    install -Dm755 "$ROOT/ui/settings/hyprdrive-power-watch" "$LIBDIR/hyprdrive-power-watch"
    subst() { # file mode dest -- @HYPRDRIVE_PREFIX@ -> PREFIX, as for the fragments
        python3 -c 'import sys; sys.stdout.write(sys.stdin.read().replace("@HYPRDRIVE_PREFIX@", sys.argv[1]))' "$PREFIX" < "$1" > "$3.tmp"
        chmod "$2" "$3.tmp" && mv -f "$3.tmp" "$3"
    }
    mkdir -p "$PREFIX/bin" "$PREFIX/share/applications"
    subst "$ROOT/ui/settings/hyprdrive-settings" 755 "$PREFIX/bin/hyprdrive-settings"
    sed "s|^Exec=hyprdrive-settings\$|Exec=$PREFIX/bin/hyprdrive-settings|" "$ROOT/ui/settings/hyprdrive-settings.desktop" \
        > "$PREFIX/share/applications/hyprdrive-settings.desktop"
    echo "settings app: $PREFIX/bin/hyprdrive-settings (QML in $SHARE)"
    # The search tools (`define`, `tr`) come switched ON with the native
    # install -- unless already set either way (hdpanel seed never overrides).
    # They need curl and jq.
    if "$LIBDIR/hdpanel" seed plugin:hyprdrive:search:dictionary true plugin:hyprdrive:search:translate true >/dev/null 2>&1; then
        echo "search tools: Dictionary + Translate on (Settings > Overview > Search)"
    else
        echo "search tools: could not seed defaults (hdpanel seed failed)" >&2
    fi
    # Mosaic comes ON with the native install too (user, 2026-10-18): Super+L
    # cycles Dwindle -> Scrolling -> Mosaic. Desktops keep their own layout
    # until you switch one; mosaic:default (new desktops in Mosaic) stays off.
    if "$LIBDIR/hdpanel" seed plugin:hyprdrive:mosaic:enabled true >/dev/null 2>&1; then
        echo "mosaic: on (Super+L cycles Dwindle -> Scrolling -> Mosaic; Settings > Mosaic)"
    else
        echo "mosaic: could not seed the default (hdpanel seed failed)" >&2
    fi
    for t in curl jq; do
        command -v "$t" >/dev/null 2>&1 || echo "search tools: needs $t (define/translate)" >&2
    done
    # This version's 40-panel.lua, from the settings already saved (hdpanel
    # refresh, which changes none of them): a switch a release turns on by
    # default -- Super+D's show desktop -- is bound without a visit to them.
    if "$LIBDIR/hdpanel" refresh >/dev/null 2>&1; then
        echo "keybinds: 40-panel.lua rewritten from your settings (show desktop on Super+D unless you turned it off)"
    else
        echo "keybinds: could not rewrite 40-panel.lua (hdpanel refresh failed)" >&2
    fi
    command -v qs >/dev/null 2>&1 || echo "settings app: needs Quickshell 0.3 (qs) to run" >&2
    exit 0
fi

# INSTALLED FROM THE MARKETPLACE: `omarchy plugin add` cloned this very
# repository into $PLUGIN_DEST, and its root manifest.json points the shell at
# ui/Panel.qml. The panel is already installed -- it IS this
# checkout -- and copying ui/ over the clone's root would dirty it
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
import json, os, sys
m = json.load(open(sys.argv[1]))
m["entryPoints"] = {k: v.split("/")[-1] for k, v in m.get("entryPoints", {}).items()}
text = json.dumps(m, indent=2, ensure_ascii=False) + "\n"
# Unchanged, untouched: a rewrite is a plugin reload in the shell for nothing.
try:
    if open(sys.argv[2]).read() == text:
        sys.exit(0)
except OSError:
    pass
# Atomic (review, 2026-11-09): the shell reads this manifest whenever it likes.
tmp = sys.argv[2] + ".tmp"
with open(tmp, "w") as fh:
    fh.write(text)
os.replace(tmp, sys.argv[2])
PY
    # -C: a file whose content did not change keeps its time, so a reinstall
    # of the same panel does not read as a newer one (hdpanel shell-stale).
    install -C -Dm644 "$PLUGIN_SRC/Panel.qml" "$PLUGIN_DEST/Panel.qml"
    install -C -Dm644 "$PLUGIN_SRC/HyprdrivePanel.qml" "$PLUGIN_DEST/HyprdrivePanel.qml"
    install -C -Dm644 "$PLUGIN_SRC/Schema.js" "$PLUGIN_DEST/Schema.js"
    install -C -Dm644 "$PLUGIN_SRC/Model.js" "$PLUGIN_DEST/Model.js"
    install -C -Dm644 "$PLUGIN_SRC/README.md" "$PLUGIN_DEST/README.md"
    install -C -Dm644 "$PLUGIN_SRC/hyprdrive-icon.png" "$PLUGIN_DEST/hyprdrive-icon.png"
    install -C -Dm755 "$PLUGIN_SRC/bin/hdpanel" "$PLUGIN_DEST/bin/hdpanel"
    install -C -Dm755 "$PLUGIN_SRC/bin/hdicons" "$PLUGIN_DEST/bin/hdicons"
    install -C -Dm755 "$PLUGIN_SRC/bin/hyprdrive" "$PLUGIN_DEST/bin/hyprdrive"
    # Super+L's layout cycle while the panel's Mosaic switch is on; 40-panel.lua
    # binds it by this path (hdpanel's LAYOUT_CYCLE, beside hdpanel itself).
    install -C -Dm755 "$PLUGIN_SRC/bin/hd-layout-cycle" "$PLUGIN_DEST/bin/hd-layout-cycle"
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

# A PANEL OLDER THAN ITS FILES (user, 2026-11-10: "the setting is not
# visible"). The Omarchy shell compiles the settings panel once and keeps it:
# its plugin reload on the copy above rebuilds from that old copy
# (omacom/omarchy#6981), so a new panel shows only after the shell restarts.
# Restart it now when it started before the panel's QML/JS last changed, with
# Omarchy's own omarchy-restart-shell (it refuses while the session is locked).
# `hyprdrive update` sets HYPRDRIVE_SHELL_RESTART=0 and restarts it after the
# plugin reload instead, so the new panel and the new plugin start together.
if [ -d "$PLUGIN_DEST" ] && [ "$(cd "$PLUGIN_DEST" && pwd -P)" = "$(cd "$ROOT" && pwd -P)" ]; then
    PANEL_CTL=$ROOT/ui/bin/hdpanel
else
    PANEL_CTL=$PLUGIN_DEST/bin/hdpanel
fi
# This version's 40-panel.lua, from the settings already saved (hdpanel
# refresh, which changes none of them): a switch a release turns on by default
# -- Super+D's show desktop -- is bound without a visit to them.
if [ -x "$PANEL_CTL" ]; then
    if "$PANEL_CTL" refresh >/dev/null 2>&1; then
        echo "keybinds: 40-panel.lua rewritten from your settings (show desktop on Super+D unless you turned it off)"
    else
        echo "keybinds: could not rewrite 40-panel.lua (hdpanel refresh failed)" >&2
    fi
fi
if [ "${HYPRDRIVE_SHELL_RESTART:-1}" != 0 ] && [ -x "$PANEL_CTL" ] &&
   command -v omarchy-restart-shell >/dev/null 2>&1 && why=$("$PANEL_CTL" shell-stale); then
    echo "shell restart: $why"
    if omarchy-restart-shell; then
        echo "shell restart: done -- the settings panel is the new one"
    else
        echo "shell restart: not done (see above); run omarchy-restart-shell to see the new settings" >&2
    fi
fi
