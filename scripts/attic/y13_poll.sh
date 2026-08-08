#!/usr/bin/env bash
# Y13 instrument. Runs OUTSIDE the Hyprland session (setsid) so it survives the
# GDM restart, and measures from the moment a NEW compositor instance appears --
# not from when hyprrestart.sh returns, which is already well after quickshell
# is up and was the first measurement's mistake.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
OLD=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
echo "old instance: $OLD" > /tmp/y13.log

# wait for a new instance signature
for i in $(seq 1 600); do
    NEW=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
    [ -n "$NEW" ] && [ "$NEW" != "$OLD" ] && break
    sleep 0.2
done
T0=$(date +%s.%N)
export HYPRLAND_INSTANCE_SIGNATURE=$NEW
echo "new instance: $NEW at $(date -u +%H:%M:%S.%3N)" >> /tmp/y13.log

qsproc=""; qslayer=""; bglayer=""
for i in $(seq 1 400); do
    EL=$(echo "$(date +%s.%N) - $T0" | bc)
    [ -z "$qsproc" ]  && pgrep -x qs >/dev/null && qsproc=$EL  && echo "qs-proc  ${EL}s" >> /tmp/y13.log
    L=$(hyprctl layers 2>/dev/null | grep -c "namespace: quickshell")
    B=$(hyprctl layers 2>/dev/null | grep -c "namespace: quickshell:background")
    [ -z "$qslayer" ] && [ "${L:-0}" -gt 0 ] && qslayer=$EL && echo "qs-layer ${EL}s" >> /tmp/y13.log
    [ -z "$bglayer" ] && [ "${B:-0}" -gt 0 ] && bglayer=$EL && echo "bg-layer ${EL}s" >> /tmp/y13.log && break
    sleep 0.2
done
echo "SUMMARY qsproc=${qsproc:-never} qslayer=${qslayer:-never} bglayer=${bglayer:-never}" >> /tmp/y13.log
