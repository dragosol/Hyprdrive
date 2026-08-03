#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC 13.9 X35: the dock's LOCATIONS -- the trash, and mounted
# volumes. Runs IN THE GUEST; every pixel claim is made on the host by
# share/x35_gate.py, because the guest has no numpy.
#
# The rules earlier rigs paid for are still in force:
#   * ydotool's absolute space is HALF this guest's output.
#   * a capture identical to its control is a FAIL, not a pass: a starved output
#     hands back the same frame forever and that reads as "nothing changed".
#   * so every measurement is a TRIPLE -- control, measured, control -- and the
#     two controls must match each other or the phase is void.
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=$(basename $(ls -t /run/user/1000/wayland-* | grep -v lock | head -1))
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/x35shots
mkdir -p $OUT

key()  { hyprctl eval "return hl.config({ plugin = { scrolloverview = { dock = { $1 = $2 } } } })" >/dev/null; }
dsp()  { hyprctl eval "return hl.dispatch($1)" >/dev/null; }
warp() { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; sleep 0.3; }
rmb()  { ydotool click 0xC1 2>/dev/null; sleep 0.6; }

read -r MON W H <<< "$(hyprctl monitors -j | python3 -c "
import json,sys
m = json.load(sys.stdin)[0]
print(m['name'], m['width'], m['height'])")"
shot() { sleep 0.5; grim -o "$MON" $OUT/$1.png; }
park() { warp $((W / 2)) $((H / 3)); }

# The trash poll is 1s (the reference's UPDATE_TRASH_DELAY), and the icon only
# reaches the screen on the next frame that gets asked for -- so settling is
# "wait out the poll, then nudge the pointer to force a frame".
settle() { sleep 1.4; warp $((W / 2)) $((H / 3 + 7)); sleep 0.4; park; }

# Every phase re-asserts it, because the overview closes on its own between
# runs and a control frame taken with it shut looks nothing like the next one --
# which reads as "the desk moved" and voids the phase rather than failing it.
# The 3.5s is not padding: the overview's own open animation is still moving the
# workspace strip after 1.5s, and the strip's bottom edge crosses the band the
# pill is measured in -- so a control frame taken too early differs from the one
# taken at the end of the phase by the whole strip, and voids it.
open_ov() {
    dsp "hl.plugin.scrolloverview.overview([[on]])" 2>/dev/null
    sleep 3.5; park; sleep 1.0
}

case "${1:?usage: x35_rig.sh <phase>}" in

fixture)
    systemctl --user stop hyprwall.timer 2>/dev/null
    systemd-run --user --on-active=40min systemctl --user start hyprwall.timer >/dev/null 2>&1

    dsp "hl.plugin.scrolloverview.overview([[off]])" 2>/dev/null; sleep 0.5
    pkill -f kitty 2>/dev/null; sleep 1.0
    dsp "hl.dsp.focus({ workspace = 1 })"; sleep 0.6
    # kitty, NEVER foot: the standing rule -- foot does not take on the frost
    # kitty does, so a rig full of foot makes every capture look wrong. setsid
    # -f because a plain background job dies with the ssh that started it.
    for i in 1 2; do
        setsid -f kitty --override background=#20${i}0${i}0 -o confirm_os_window_close=0 \
            sh -c 'while :; do sleep 1; done' </dev/null >/dev/null 2>&1
        sleep 1.2
    done
    sleep 1.5

    key enabled true
    key autohide false
    key notification_counter false
    key dance_urgent false
    key show_apps_button false
    key isolate_workspaces false

    # A known-empty trash is the baseline every later phase measures against.
    gio trash --empty -f 2>/dev/null
    rm -rf ~/.local/share/Trash/files/* ~/.local/share/Trash/info/* 2>/dev/null

    key show_trash true; key show_mounts false
    dsp "hl.plugin.scrolloverview.overview([[on]])"; sleep 1.2
    park
    echo "FIXTURE clients=$(hyprctl clients -j | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
    ;;

# A/B: the trash icon EXISTS. Off, on, off -- the two off frames are the
# controls, and the thing that appears between them is the icon.
ab)
    open_ov
    key show_trash false; settle; shot ab_off0
    key show_trash true;  settle; shot ab_on
    key show_trash false; settle; shot ab_off1
    key show_trash true;  settle
    echo "AB done"
    ;;

# The trash FILLS: user-trash -> user-trash-full, without a box moving. Same
# triple, and the empty frames bracket the full one.
fill)
    open_ov
    gio trash --empty -f 2>/dev/null
    rm -rf ~/.local/share/Trash/files/* ~/.local/share/Trash/info/* 2>/dev/null
    settle; shot fill_e0

    date > ~/x35victim.txt && gio trash ~/x35victim.txt
    settle; settle; shot fill_full
    echo "COUNT_FULL $(gio info -a trash::item-count trash:/// | awk '/item-count/{print $2}')"

    gio trash --empty -f 2>/dev/null
    rm -rf ~/.local/share/Trash/files/* ~/.local/share/Trash/info/* 2>/dev/null
    settle; settle; shot fill_e1
    echo "COUNT_EMPTY $(gio info -a trash::item-count trash:/// | awk '/item-count/{print $2}')"
    ;;

# The X28 menu over a LOCATION. `list_actions()` on an empty trash is [], so the
# menu has no rows; one item in it and `Empty Trash` is there. Needs the icon
# centre the ab gate found: x35_rig.sh menu <x> <y>
menu)
    X=${2:?need x}; Y=${3:?need y}
    open_ov
    gio trash --empty -f 2>/dev/null
    rm -rf ~/.local/share/Trash/files/* ~/.local/share/Trash/info/* 2>/dev/null
    settle

    warp $X $Y; sleep 0.4; shot menu_hover_e
    rmb; shot menu_empty
    warp $((W / 2)) $((H / 3)); ydotool click 0xC0 2>/dev/null; sleep 0.5   # dismiss

    date > ~/x35victim.txt && gio trash ~/x35victim.txt
    settle; settle
    warp $X $Y; sleep 0.4; shot menu_hover_f
    rmb; shot menu_full
    warp $((W / 2)) $((H / 3)); ydotool click 0xC0 2>/dev/null; sleep 0.5

    gio trash --empty -f 2>/dev/null
    rm -rf ~/.local/share/Trash/files/* ~/.local/share/Trash/info/* 2>/dev/null
    echo "MENU done at $X,$Y"
    ;;

# The MOUNTS half. `show-mounts` is false in the target config, so this phase
# turns it on to prove the code path is real rather than dead. /run/media/$USER
# is where g_unix_mount_entry_guess_should_display() looks.
mounts)
    open_ov
    key show_mounts false; settle; shot mnt_off0

    # A loopback ext4, NOT a tmpfs: glib's guess_system_internal() has tmpfs on
    # its own list, so a tmpfs is skipped no matter where it is mounted and the
    # first cut of this phase measured nothing while looking like it worked.
    dd if=/dev/zero of=/tmp/x35.img bs=1M count=16 status=none
    mkfs.ext4 -q -F /tmp/x35.img
    sudo mkdir -p /run/media/dragos/X35TEST
    sudo mount -o loop /tmp/x35.img /run/media/dragos/X35TEST
    key show_mounts true; settle; settle; shot mnt_on

    sudo umount /run/media/dragos/X35TEST; sudo rmdir /run/media/dragos/X35TEST; rm -f /tmp/x35.img
    settle; settle; shot mnt_off1
    key show_mounts false
    echo "MOUNTS done"
    ;;

*)  echo "unknown phase $1"; exit 2 ;;
esac
