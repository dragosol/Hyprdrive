#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC 13.14 Y1 + Y2, proved by INSTRUMENTATION rather than pixels.
#
# WHY NOT PIXELS. The guest renders at ~1fps whenever the host's virt-viewer
# window is buried, so grim hands back stale frames; the first cut of this check
# scored a 163px full-screen delta over 0.5s with a counter ticking every 80ms,
# and its own liveness floor correctly refused the run. The headless-output swap
# that normally fixes that ALSO stops the overview opening at all here, so both
# capture routes were dead.
#
# Y1 and Y2 are a HIT-TEST change, and a hit test is exactly what a log settles
# in one run (RICE_PROGRESS: "the file sink settled in ONE run a question two
# prior fires could not"). Dock::render writes one line per frame while
# /tmp/ovdbg.on exists: where the pointer is, whether it is on an ICON, whether
# it is inside the PLATE, whether the plate is up, and which window's title the
# tooltip resolved to.
#
# The pre-Y1 build cannot produce the line this looks for: panelUp=1 with
# hasHover=0 was unreachable, because PANELWANTED was HASHOVER and nothing else.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)

OUT=/mnt/host/y12; mkdir -p $OUT
dsp()  { hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }
ov()   { dsp "hl.plugin.scrolloverview.overview([[$1]])"; }
warp() { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; }
cfg()  { hyprctl eval "hl.config({plugin={scrolloverview={dock={$1}}}}) return 0" >/dev/null 2>&1; }

restore() {
    rm -f /tmp/ovdbg.on
    ov off
    cfg "autohide=true, show_favorites=true, show_apps_button=true, show_trash=true, show_mounts=false"
    systemctl --user start hyprwall.timer 2>/dev/null
}
trap restore EXIT

systemctl --user stop hyprwall.timer 2>/dev/null
systemd-run --user --on-active=30min systemctl --user start hyprwall.timer >/dev/null 2>&1

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5
cfg "autohide=false, show_favorites=false, show_apps_button=false, show_trash=false, show_mounts=false"
sleep 0.8

# Three windows, one class, DISTINCT TITLES -- the titles are the whole of the
# Y2 signal. Placed apart so all three are really mapped and previewable.
for t in ALPHA_ONE BRAVO_TWO CHARLIE_THREE; do
    setsid kitty -c NONE --class Y12A --title "$t" -o background='#101820' \
        -o background_opacity=1.0 -o confirm_os_window_close=0 \
        --hold sh -c 'sleep infinity' >/dev/null 2>&1 </dev/null &
    sleep 1.8
done

N=$(hyprctl clients -j | python3 -c "
import json,sys
print(sum(1 for c in json.load(sys.stdin) if c['class']=='Y12A'))")
[ "$N" = "3" ] || { echo "ABORT: expected 3 Y12A windows, got $N"; exit 1; }

read -r AX AY <<< "$(hyprctl clients -j | python3 /mnt/host/x47_cell.py Y12A)"
read -r PX PY PW PH <<< "$(hyprctl clients -j | python3 /mnt/host/x47_cell.py panel)"
echo "icon=$AX,$AY  panel y=$PY h=$PH w=$PW"

# The plate is centred on its icon, so the icon's x lands in the MIDDLE cell and
# one predicted cell-width left of it is the cell before. The predictor's panel
# X is known-wrong (RICE_PROGRESS) and is deliberately not used.
MIDX=$AX; LEFTX=$(( AX - PW / 3 )); CY=$(( PY + PH / 2 ))
W=2560; PARKX=$((W-60)); PARKY=60

ov on; sleep 2.5
warp $PARKX $PARKY; sleep 1.2

rm -f /tmp/ovdbg.log
: > /tmp/ovdbg.on          # instrumentation ON from here

echo "--- phase park"  >> /tmp/ovdbg.log; sleep 0.6
echo "--- phase icon"  >> /tmp/ovdbg.log
warp $AX $AY;    sleep 1.0
echo "--- phase mid"   >> /tmp/ovdbg.log
warp $MIDX $CY;  sleep 1.4      # >> PANEL_GRACE_MS(180) + PANEL_OUT_MS(130)
echo "--- phase left"  >> /tmp/ovdbg.log
warp $LEFTX $CY; sleep 1.2
echo "--- phase park2" >> /tmp/ovdbg.log
warp $PARKX $PARKY; sleep 2.0

rm -f /tmp/ovdbg.on
cp /tmp/ovdbg.log $OUT/probe-ovdbg.log
echo "lines: $(wc -l < /tmp/ovdbg.log)"
echo Y12_PROBE_OK
