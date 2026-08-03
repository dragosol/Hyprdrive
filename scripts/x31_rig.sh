#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC 13.9 X31 acceptance rig. Runs IN THE GUEST; the pixels are
# analysed on the HOST by share/x31_gate.py, because the guest has no numpy.
#
# Everything X31 draws lives INSIDE the pill and is small -- a 5px dot, a badge
# a few characters wide. So every phase is an A/B against the same dock with
# only the ONE key under test flipped, never against a bare desktop: that way a
# pass cannot come from the pill itself, from the wallpaper, or from a window
# repainting behind it.
#
# The counters come from the Unity LauncherEntry D-Bus protocol, which is the
# reference's own primary source (`application-counter-overrides-notifications`
# is true in the user's Dash to Dock). `gdbus emit` is therefore a REAL client
# of the shipped protocol, not a test backdoor into the plugin.
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/x31
mkdir -p $OUT

read -r MON W H <<< "$(hyprctl monitors -j | python3 -c "
import json,sys
m = json.load(sys.stdin)[0]
print(m['name'], m['width'], m['height'])")"

# `hyprctl keyword` is gone in 0.56 and exits 0 having changed nothing.
key()  { hyprctl eval "return hl.config({ plugin = { scrolloverview = { dock = { $1 = $2 } } } })" >/dev/null; }
shot() { grim -o "$MON" $OUT/$1.png; }
warp() { ydotool mousemove -a -x $1 -y $2 2>/dev/null; }
park() { warp $((W / 2)) $((H / 2)); sleep 0.4; }

# One real LauncherEntry.Update, addressed at kitty. A sender may send a SUBSET
# of the properties, so the rig sends subsets too -- if the plugin rebuilt state
# from blank per signal, `urgent` here would silently clear the count.
emit() { gdbus emit --session --object-path / \
    --signal com.canonical.Unity.LauncherEntry.Update \
    "application://kitty.desktop" "$1" >/dev/null 2>&1; }

allon()  { key running_indicator true;  key notification_counter true;  key dance_urgent true; }
alloff() { key running_indicator false; key notification_counter false; key dance_urgent false; }

case "${1:?usage: x31_rig.sh <phase>}" in

fixture)
    # A wallpaper rotation moves every pixel and this rig is entirely pixel-based.
    systemctl --user stop hyprwall.timer 2>/dev/null
    systemd-run --user --on-active=40min systemctl --user start hyprwall.timer >/dev/null 2>&1

    hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[off]]))" >/dev/null 2>&1
    sleep 0.5
    pkill -f 'kitty --class X3' 2>/dev/null; sleep 0.6
    # PLAIN `kitty`, no --class: the badge is looked up by DESKTOP ID, and
    # AppSearch::idForClass can only reach kitty.desktop from the class kitty.
    # kitty and never foot, per the standing frost rule.
    setsid -f kitty --override background=#202020 -o confirm_os_window_close=0 \
        sh -c 'while :; do sleep 1; done' </dev/null >/dev/null 2>&1
    sleep 2.5

    key enabled  true
    key autohide false          # pill simply out: every phase below measures INSIDE it
    key indicator_size  5
    key indicator_color "[[rgba(fafafbff)]]"
    key emblems true
    key urgent_notify true
    alloff
    emit "{'count-visible': <false>, 'urgent': <false>}"
    park; sleep 1.5
    echo "X31_FIXTURE mon=$MON ${W}x${H} clients=$(hyprctl clients | grep -c 'class: kitty')"
    ;;

# Controls: the dock is OUT, but every X31 feature is off. Three of them, so the
# gate has two gaps to build a noise mask from -- a caret blinking inside a
# terminal is change that is not a badge.
base)
    park
    sleep 1.2; shot off1
    sleep 1.2; shot off2
    sleep 1.2; shot off3
    echo BASE_OK
    ;;

# P1. `show-running-indicator`. Two frames: the stock 5px dot, then a
# deliberately large recoloured one. The pair is what proves indicator_size and
# indicator_color are READ rather than a fixed dot being drawn.
dot)
    key running_indicator true; sleep 1.2; shot dot
    key indicator_size 24; key indicator_color "[[rgba(ff0000ff)]]"
    sleep 1.2; shot dotbig
    key indicator_size 5; key indicator_color "[[rgba(fafafbff)]]"
    key running_indicator false; sleep 1.0
    echo DOT_OK
    ;;

# P2. Notification counters over LauncherEntry. The count is broadcast FIRST and
# left standing for all three frames, so the only difference between the control
# and the badge frames is the config key -- a pass cannot come from the emit
# itself repainting something.
badge)
    emit "{'count': <int64 5>, 'count-visible': <true>}"
    sleep 1.0
    park; sleep 1.0; shot badge_off1
          sleep 1.0; shot badge_off2
    key notification_counter true
    sleep 1.2; shot badge5
    # Second property push, count only. If state were rebuilt per signal the
    # `count-visible` from the first emit would be gone and the badge would
    # vanish instead of changing.
    emit "{'count': <int64 99999>}"
    sleep 1.2; shot badge99k
    key notification_counter false
    emit "{'count-visible': <false>}"
    sleep 1.0
    echo BADGE_OK
    ;;

# P3. Urgency wiggle. The reference moves the icon for the first 1/6 of a 3000ms
# cycle and leaves it still for the rest, so this photographs a BURST: the gate
# compares how much the frames differ from EACH OTHER against a still set taken
# with dance-urgent off and the app equally urgent. Comparing a moving icon with
# a non-urgent one would pass on the urgency alone.
wiggle)
    emit "{'urgent': <true>}"
    key dance_urgent false; sleep 1.2
    for i in $(seq 1 14); do shot still$i; done
    key dance_urgent true; sleep 0.3
    for i in $(seq 1 28); do shot wig$i; done
    key dance_urgent false; sleep 0.8
    echo WIGGLE_OK
    ;;

# P4. `show-dock-urgent-notify`: an urgent app pulls a HIDDEN dock out with no
# pointer anywhere near the barrier. dance_urgent stays off so the only thing
# that can move is the pill.
notify)
    key dance_urgent false
    emit "{'urgent': <false>}"
    key autohide true; park; sleep 3.0
    shot nof1; sleep 1.2; shot nof2
    emit "{'urgent': <true>}"
    sleep 3.0; shot non1
    # ...and the same urgent state with the key off leaves it hidden. Measured
    # 2026-08-03: the hide settles slower than the reveal, and 2s photographed a
    # dock still on its way down.
    key urgent_notify false; sleep 5.0; shot noff
    key urgent_notify true
    emit "{'urgent': <false>}"
    key autohide false; park; sleep 1.5
    echo NOTIFY_OK
    ;;

*)
    echo "ABORT: unknown phase $1"; exit 1 ;;
esac
