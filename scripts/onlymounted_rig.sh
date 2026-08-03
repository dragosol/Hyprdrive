#!/usr/bin/env bash
# Does `show_mounts_only_mounted false` actually put an UNMOUNTED volume on the
# dock? The key was registered by X35 and read by nothing, so until now it could
# be set either way with no effect at all.
#
# The fixture is an fstab entry that is user-mountable and NOT mounted, which is
# the only thing the false case is supposed to add. It writes the shots under the
# names x35_gate.py's `mounts` phase already expects, because the claim is the
# same shape as that phase's -- a location blob that appears between two control
# frames -- and a second gate for the same shape would be a second thing to keep
# honest.
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=$(basename $(ls -t /run/user/1000/wayland-* | grep -v lock | head -1))
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/x35shots
mkdir -p $OUT

read -r MON W H <<< "$(hyprctl monitors -j | python3 -c "
import json,sys
m = json.load(sys.stdin)[0]
print(m['name'], m['width'], m['height'])")"

key()  { hyprctl eval "return hl.config({ plugin = { scrolloverview = { dock = { $1 = $2 } } } })" >/dev/null; }
dsp()  { hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }
warp() { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; sleep 0.3; }
park() { warp $((W / 2)) $((H / 3)); }
shot() { sleep 0.5; grim -o "$MON" $OUT/$1.png; }
settle() { sleep 1.4; warp $((W / 2)) $((H / 3 + 7)); sleep 0.4; park; }

MP=/mnt/x35only
IMG=/tmp/x35only.img
FSTAB_LINE="$IMG $MP ext4 user,noauto,loop 0 0"

case "${1:?usage: onlymounted_rig.sh <setup|run|teardown>}" in

setup)
    dd if=/dev/zero of=$IMG bs=1M count=16 status=none
    mkfs.ext4 -q -F $IMG
    sudo mkdir -p $MP
    grep -qF "$IMG" /etc/fstab || echo "$FSTAB_LINE" | sudo tee -a /etc/fstab >/dev/null
    # It must stay UNMOUNTED: a mounted one would show up in the `true` control
    # too, and the phase would pass without the key doing anything.
    mountpoint -q $MP && sudo umount $MP
    echo "SETUP fstab=$(grep -c "$IMG" /etc/fstab) mounted=$(mountpoint -q $MP && echo yes || echo no)"
    ;;

run)
    dsp "hl.plugin.scrolloverview.overview([[on]])"; sleep 3.5; park; sleep 1.0
    key show_mounts true
    key show_mounts_only_mounted true;  settle; settle; shot mnt_off0
    key show_mounts_only_mounted false; settle; settle; shot mnt_on
    key show_mounts_only_mounted true;  settle; settle; shot mnt_off1
    dsp "hl.plugin.scrolloverview.overview([[off]])"
    echo "RUN done -> $OUT"
    ;;

teardown)
    sudo sed -i "\|$IMG|d" /etc/fstab
    mountpoint -q $MP && sudo umount $MP
    sudo rmdir $MP 2>/dev/null
    rm -f $IMG
    key show_mounts_only_mounted true
    key show_mounts false
    echo "TEARDOWN fstab=$(grep -c "$IMG" /etc/fstab || true)"
    ;;

*) echo "unknown $1"; exit 2 ;;
esac
