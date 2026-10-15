#!/usr/bin/env bash
# Remove Hyprdrive: everything scripts/install-fragments.sh put in place.
#
#   - the plugin:        $PREFIX/lib/hyprdrive/ (PREFIX default ~/.local)
#   - the CLIs:          $PREFIX/bin/hyprdrive-integration, hyprdrive-layout-cycle
#   - the settings app:  $PREFIX/bin/hyprdrive-settings, $PREFIX/share/hyprdrive,
#                        its .desktop entry (plain Hyprland installs)
#   - the fragments:     ~/.config/hypr/hyprdrive/  (moved aside, not deleted:
#                        their raw-snippet blocks are the user's own edits)
#   - the loader:        ~/.config/hypr/hyprdrive.lua
#   - the require block install-fragments appended to ~/.config/hypr/hyprland.lua
#   - the settings panel, when it was copied there by `make install`. A panel
#     the marketplace installed is a git checkout: `omarchy plugin remove
#     dragos.hyprdrive` removes that one, and this script says so.
#
# Left alone: ~/.local/state/hyprdrive (favourites, stacks, Mosaic sizes),
# so a reinstall picks up where it was. Delete it by hand to start fresh.
#
# The compositor keeps the plugin it already loaded until the session ends:
# log out and back in (or restart Hyprland) to finish. Unloading it live is
# not done here -- a live unload mid-gesture can take the session down.
set -eu
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}
PREFIX=${PREFIX:-$HOME/.local}
LIBDIR=$PREFIX/lib/hyprdrive
CLI=$PREFIX/bin/hyprdrive-integration
FRAGS=$CONFIG/hypr/hyprdrive
LOADER=$CONFIG/hypr/hyprdrive.lua
HYPRLAND_LUA=$CONFIG/hypr/hyprland.lua
PANEL=$CONFIG/omarchy/plugins/dragos.hyprdrive

if [ -d "$LIBDIR" ]; then rm -rf "$LIBDIR"; echo "removed $LIBDIR"; fi
if [ -f "$CLI" ]; then rm -f "$CLI"; echo "removed $CLI"; fi
for f in "$PREFIX/bin/hyprdrive-settings" "$PREFIX/bin/hyprdrive-layout-cycle" "$PREFIX/share/applications/hyprdrive-settings.desktop"; do
    if [ -f "$f" ]; then rm -f "$f"; echo "removed $f"; fi
done
if [ -d "$PREFIX/share/hyprdrive/settings" ]; then
    rm -rf "$PREFIX/share/hyprdrive/settings"
    rmdir "$PREFIX/share/hyprdrive" 2>/dev/null || true
    echo "removed the settings app from $PREFIX/share/hyprdrive"
fi

if [ -d "$FRAGS" ]; then
    BACKUP="$FRAGS.removed-$(date +%Y%m%d-%H%M%S)"
    mv "$FRAGS" "$BACKUP"
    echo "fragments moved to $BACKUP (delete it once you are sure)"
fi

if [ -f "$LOADER" ]; then rm -f "$LOADER"; echo "removed $LOADER"; fi

# Either spelling install-fragments writes: require("hypr.hyprdrive") on
# Omarchy, require("hyprdrive") on plain Hyprland.
if [ -f "$HYPRLAND_LUA" ] && grep -Eq '^require\("(hypr\.)?hyprdrive"\)' "$HYPRLAND_LUA"; then
    # Exactly the block install-fragments appends: its comment and the require.
    python3 - "$HYPRLAND_LUA" <<'PY'
import sys, re, os, stat
p = sys.argv[1]
# The backup is created with hyprland.lua's own mode: a private 0600 config
# must not reappear as a umask-default 0644 copy (marketplace review, #11012).
mode = stat.S_IMODE(os.stat(p).st_mode)
s = open(p).read()
s2 = re.sub(r'\n?-- Hyprdrive \(overview \+ dock\)\. Fragments live in hypr/hyprdrive/\.\n', '\n', s)
s2 = re.sub(r'^require\("(hypr\.)?hyprdrive"\)\n?', '', s2, flags=re.M)
if s2 != s:
    bak = p + ".hyprdrive-bak"
    if os.path.lexists(bak):
        os.unlink(bak)
    with os.fdopen(os.open(bak, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode), "w") as fh:
        fh.write(s)
    os.chmod(bak, mode)
    open(p, "w").write(s2)
    print(f"removed the hyprdrive require() from {p} (backup: {p}.hyprdrive-bak)")
PY
fi

if [ -d "$PANEL" ]; then
    if [ -d "$PANEL/.git" ]; then
        echo "settings panel installed from the marketplace: run  omarchy plugin remove dragos.hyprdrive"
    else
        rm -rf "$PANEL"
        echo "removed settings panel $PANEL"
    fi
fi

echo "done -- log out and back in to unload the running plugin"
