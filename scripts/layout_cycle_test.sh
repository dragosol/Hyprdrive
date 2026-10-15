#!/usr/bin/env bash
# Host test for omarchy-plugin/bin/hd-layout-cycle (installed natively as
# hyprdrive-layout-cycle; audit A18 / inventory J4). No compositor: hyprctl,
# gdbus, notify-send, the integration CLI and omarchy-notification-send are
# stand-ins on a private PATH that record what they were asked.
#
# Covers: the cycle order (dwindle -> scrolling -> mosaic -> dwindle), Mosaic
# only while plugin:hyprdrive:mosaic:enabled is on (and not at all when the
# option does not exist), the 45-workspace-layouts.lua fragment (one line per
# workspace, replaced in place, numeric order, mode kept), the live rule, the
# notification only when a daemon owns org.freedesktop.Notifications, and the
# Omarchy path (Omarchy's state file + omarchy-notification-send, no fragment).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/omarchy-plugin/bin/hd-layout-cycle
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
check() { # name cond...
    local name=$1; shift
    if "$@"; then echo "  ok   $name"; else echo "  FAIL $name"; fails=$((fails + 1)); fi
}

FAKE=$T/bin; mkdir -p "$FAKE"
LOG=$T/log
cat > "$FAKE/hyprctl" <<'EOF'
#!/bin/bash
echo "hyprctl $*" >> "$LOG"
case "$1" in
  activeworkspace) printf '{"id": %s, "tiledLayout": "%s"}\n' "$FAKE_WS" "$FAKE_LAYOUT" ;;
  getoption)
    case "$FAKE_MOSAIC" in
      on) echo '{"option": "plugin:hyprdrive:mosaic:enabled", "int": 1, "set": true}' ;;
      off) echo '{"option": "plugin:hyprdrive:mosaic:enabled", "int": 0, "set": true}' ;;
      *) echo "no such option" ;;
    esac ;;
  hyprdrive-integration) echo "$FAKE_DESKTOP" ;;
  eval) exit 0 ;;
esac
EOF
cat > "$FAKE/hyprdrive-integration" <<'EOF'
#!/bin/bash
echo "$FAKE_DESKTOP"
EOF
cat > "$FAKE/gdbus" <<'EOF'
#!/bin/bash
echo "gdbus $*" >> "$LOG"
echo "($FAKE_NOTIFIER,)"
EOF
cat > "$FAKE/notify-send" <<'EOF'
#!/bin/bash
echo "notify-send $*" >> "$LOG"
EOF
cat > "$FAKE/omarchy-notification-send" <<'EOF'
#!/bin/bash
echo "omarchy-notification-send $*" >> "$LOG"
EOF
chmod +x "$FAKE"/*
for tool in jq timeout mktemp grep sort chmod mv mkdir dirname readlink head cat printf; do
    p=$(command -v "$tool") && ln -sf "$p" "$FAKE/$tool"
done

export LOG HOME=$T/home XDG_CONFIG_HOME=$T/home/.config
unset HYPRDRIVE_FRAGMENTS
FRAG=$XDG_CONFIG_HOME/hypr/hyprdrive/45-workspace-layouts.lua
mkdir -p "$HOME"

run() { # ws layout mosaic notifier desktop
    : > "$LOG"
    FAKE_WS=$1 FAKE_LAYOUT=$2 FAKE_MOSAIC=$3 FAKE_NOTIFIER=$4 FAKE_DESKTOP=$5 \
        PATH=$FAKE /bin/bash "$SCRIPT"
}
rules() { grep -E '^hl\.workspace_rule' "$FRAG" | tr '\n' '|'; }
logged() { grep -qF -- "$1" "$LOG"; }

echo "layout_cycle_test:"
run 1 dwindle on false none; rc=$?
check "exit 0" [ $rc = 0 ]
check "dwindle -> scrolling, persisted" [ "$(rules)" = 'hl.workspace_rule({ workspace = "1", layout = "scrolling" })|' ]
check "fragment has the 45-workspace-layouts header" grep -q '^-- hyprdrive fragment 45-workspace-layouts' "$FRAG"
check "applied live" logged 'hyprctl eval hl.workspace_rule({ workspace = "1", layout = "scrolling" })'
check "no daemon: no notify-send" bash -c "! grep -q '^notify-send' '$LOG'"
check "no daemon: asked the bus" logged 'NameHasOwner org.freedesktop.Notifications'

chmod 600 "$FRAG"
run 2 scrolling on true none
check "scrolling -> mosaic while Mosaic is on" logged 'layout = "mosaic"'
check "notify-send when a daemon owns the name" logged 'notify-send -a Hyprdrive -t 2000 Workspace layout set to Mosaic'
check "fragment mode kept (0600)" [ "$(stat -c %a "$FRAG")" = 600 ]

run 10 scrolling off false none
check "scrolling -> dwindle while Mosaic is off" logged 'hyprctl eval hl.workspace_rule({ workspace = "10", layout = "dwindle" })'
run 3 scrolling missing false none
check "scrolling -> dwindle without the plugin's option" logged 'hyprctl eval hl.workspace_rule({ workspace = "3", layout = "dwindle" })'
run 2 mosaic on false none
check "mosaic -> dwindle" logged 'hyprctl eval hl.workspace_rule({ workspace = "2", layout = "dwindle" })'
check "one line per workspace, replaced in place, numeric order" \
    [ "$(rules)" = 'hl.workspace_rule({ workspace = "1", layout = "scrolling" })|hl.workspace_rule({ workspace = "2", layout = "dwindle" })|hl.workspace_rule({ workspace = "3", layout = "dwindle" })|hl.workspace_rule({ workspace = "10", layout = "dwindle" })|' ]

before=$(cat "$FRAG")
run 4 dwindle on true omarchy
check "omarchy: Omarchy's state file" grep -qx 'hl.workspace_rule({ workspace = "4", layout = "scrolling" })' "$HOME/.local/state/omarchy/workspace-layouts/4.lua"
check "omarchy: fragment untouched" [ "$before" = "$(cat "$FRAG")" ]
check "omarchy: omarchy-notification-send" logged 'omarchy-notification-send -g'
check "omarchy: no plain notify-send" bash -c "! grep -q '^notify-send' '$LOG'"

: > "$LOG"
FAKE_WS=special FAKE_LAYOUT=dwindle FAKE_MOSAIC=on FAKE_NOTIFIER=false FAKE_DESKTOP=none PATH=$FAKE /bin/bash "$SCRIPT" 2>/dev/null; rc=$?
check "a non-numeric workspace is refused" [ $rc != 0 ]

echo "layout_cycle_test: $([ $fails = 0 ] && echo OK || echo "$fails FAILED")"
exit $((fails > 0))
