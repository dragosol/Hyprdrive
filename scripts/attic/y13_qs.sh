#!/usr/bin/env bash
# Y13: how long does QUICKSHELL alone take to put the wallpaper up?
# Restarting qs is a faithful proxy for its share of the restart cost and
# iterates in seconds instead of the ~90s a full GDM cycle takes.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
export QT_QPA_PLATFORM=wayland
LABEL=${1:-baseline}
pkill -x qs 2>/dev/null; sleep 3
T0=$(date +%s.%N)
setsid qs -c ii >/tmp/qs_start.log 2>&1 &
first=""; bg=""
for i in $(seq 1 400); do
    EL=$(echo "$(date +%s.%N) - $T0" | bc)
    L=$(hyprctl layers 2>/dev/null | grep -c "namespace: quickshell")
    B=$(hyprctl layers 2>/dev/null | grep -c "namespace: quickshell:background")
    [ -z "$first" ] && [ "${L:-0}" -gt 0 ] && first=$EL
    [ -z "$bg" ] && [ "${B:-0}" -gt 0 ] && bg=$EL && break
    sleep 0.1
done
echo "$LABEL: first-surface=${first:-never}s  wallpaper=${bg:-never}s"
