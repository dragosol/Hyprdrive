#!/usr/bin/env bash
# Install a Nautilus script that pins the selected file or folder to the dock.
#
# WHY THIS EXISTS. V11 V4 asks for a stack to be created by DRAGGING a file
# from a file manager onto the dock. That gesture cannot reach this plugin. In
# Hyprland 0.56 the drop target of an XDG drag is always a wl_surface --
# CSeatManager's dndPointerFocus is a WP<CWLSurfaceResource> and
# CWLDataDeviceProtocol::updateDrag routes enter/motion/drop to one and nothing
# else -- and this dock is not a surface: it is drawn straight into the
# monitor's render pass, so there is no object the compositor could focus.
# Every member that would let a non-surface claim an offer is private, with
# `friend` limited to CSeatManager. The full finding is in DockStacks.hpp.
#
# So the pin is reachable two honest ways instead: the `hyprdrive:stack`
# dispatcher, and this -- a right-click away in the file manager's own menu,
# which is as close to the asked-for gesture as the platform allows.
set -eu
DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nautilus/scripts"
mkdir -p "$DIR"
cat > "$DIR/Pin to Dock" <<'SCRIPT'
#!/usr/bin/env bash
# Nautilus hands the selection in NAUTILUS_SCRIPT_SELECTED_FILE_PATHS, one path
# per line. hyprctl dispatch parses its argument as Lua on 0.56, so the path
# goes inside a [[long bracket]] -- which is also why it needs no quoting of
# spaces, and why a path containing "]]" is the one case this refuses.
set -eu
while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in *']]'*) continue ;; esac
    hyprctl dispatch "hl.plugin.hyprdrive.stack([[toggle $p]])" >/dev/null 2>&1 || true
done <<< "${NAUTILUS_SCRIPT_SELECTED_FILE_PATHS:-}"
SCRIPT
chmod 755 "$DIR/Pin to Dock"
echo "installed: $DIR/Pin to Dock"
echo "right-click a file or folder in Files -> Scripts -> Pin to Dock"
