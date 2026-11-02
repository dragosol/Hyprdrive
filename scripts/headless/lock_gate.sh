#!/bin/bash
# lock_gate.sh SO -- the lock screen owns the keyboard (marketplace review, #11392).
# Headless: an overview open with search text typed, then a real hyprlock locks
# the session. The overview must close and drop its query; keys typed while
# locked must not become search text; no overview may open while locked.
SO=${1:?usage: lock_gate.sh hyprdrive.so}
export HL_NAME=lockgate
H=$(dirname "$(readlink -f "$0")")/hl.sh
ST=/tmp/hl-$HL_NAME; RT=$ST/rt
fail=0; pass=0
ok() { if eval "$1"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2 ($S)"; fi; }
state() { S=$($H h dispatch 'hl.plugin.hyprdrive.debug("lockstate")' 2>&1 | grep -o 'locked=.*' | head -1); }
get() { echo "$S" | grep -o "$1=[0-9]*" | cut -d= -f2; }

$H stop >/dev/null 2>&1
$H start --so "$SO" >/dev/null || { echo "start failed"; exit 1; }
trap '$H stop >/dev/null 2>&1' EXIT
$H win kitty >/dev/null; sleep 0.8

$H overview "toggle all" >/dev/null; sleep 0.8
$H type abc >/dev/null; sleep 0.4
state; ok '[ "$(get locked)" = 0 ] && [ "$(get overviews)" -ge 1 ] && [ "$(get qlen)" = 3 ]' "unlocked: the overview is up and takes the search"

WL=$(cat $ST/wl)
# A config of its own: the test account has none, and hyprlock exits without one.
sudo -n -u hyprtest sh -c "printf 'background {\n  color = rgb(202020)\n}\ninput-field {\n  size = 200, 50\n}\n' > $ST/hyprlock.conf"
sudo -n -u hyprtest env XDG_RUNTIME_DIR=$RT WAYLAND_DISPLAY=$WL hyprlock -c $ST/hyprlock.conf --immediate-render >/dev/null 2>&1 &
for _ in $(seq 50); do state; [ "$(get locked)" = 1 ] && break; sleep 0.1; done
ok '[ "$(get locked)" = 1 ]' "hyprlock locked the session"
sleep 1.2
state; ok '[ "$(get overviews)" = 0 ] && [ "$(get qlen)" = 0 ] && [ "$(get accepting)" = 0 ]' "locking closed the overview and dropped its query"

$H type xyz >/dev/null; sleep 0.4
state; ok '[ "$(get qlen)" = 0 ]' "keys typed while locked are not search text"

# From no overview at all (a build that kept one open would close it here).
state; [ "$(get overviews)" = 0 ] || { $H overview "toggle all" >/dev/null; sleep 0.8; }
$H overview "toggle all" >/dev/null; sleep 0.8
$H type q >/dev/null; sleep 0.3
state; ok '[ "$(get overviews)" = 0 ] && [ "$(get qlen)" = 0 ]' "no overview opens while locked (dispatcher)"
state; ok '[ "$(get locked)" = 1 ]' "still locked"

sudo -n -u hyprtest pkill -x hyprlock 2>/dev/null
echo "lock_gate: $pass passed, $fail failed"
exit $((fail > 0))
