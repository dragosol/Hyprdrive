#!/usr/bin/env bash
# Z2 (user report, 2026-08-07): "clicking the dock preview window does not go to
# that window - needs fixing".
#
# The fixture window lives on ANOTHER DESKTOP, deliberately: "go to that window"
# then has two observable halves -- the view must land on its desktop AND it
# must be the focused window -- and neither can be satisfied by accident by a
# click that merely fell through to whatever was underneath.
#
# TWO CLICKS, and the first is the control. A click at the same height but well
# clear of the plate must NOT activate the window; without it, a rig that
# activated the window for any reason at all would still read as a pass.
#
# Runs IN THE GUEST. Prints its own verdict -- the measurements are workspace
# ids and window addresses, not pixels, so there is nothing for the host to
# count.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)

TAG=${1:?usage: z2_rig.sh <tag>}
OUT=/mnt/host/z2; mkdir -p $OUT

WS_HOME=1
WS_AWAY=7

dsp()   { hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }
ov()    { dsp "hl.plugin.scrolloverview.overview([[$1]])"; }
warp()  { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; }
cfg()   { hyprctl eval "hl.config({plugin={scrolloverview={dock={$1}}}}) return 0" >/dev/null 2>&1; }
click() { ydotool click 0x40; sleep 0.12; ydotool click 0x80; }

act()   { hyprctl activeworkspace -j | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])"; }
focused() { hyprctl activewindow -j | python3 -c "
import json,sys
d=json.load(sys.stdin) or {}
print(d.get('address','none'))"; }

restore() {
    ov off
    cfg "autohide=true, show_favorites=true, show_apps_button=true, show_trash=true, show_mounts=false"
    dsp "hl.dsp.focus({workspace = $WS_HOME})"
    hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = false})" >/dev/null 2>&1
    sleep 1.2
    for m in $(hyprctl monitors all -j | python3 -c "
import json,sys
print(' '.join(m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')))"); do
        hyprctl output remove "$m" >/dev/null 2>&1; sleep 0.4
    done
    systemctl --user start hyprwall.timer 2>/dev/null
}
trap restore EXIT

systemctl --user stop hyprwall.timer 2>/dev/null
systemd-run --user --on-active=30min systemctl --user start hyprwall.timer >/dev/null 2>&1

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5
dsp "hl.dsp.focus({workspace = $WS_HOME})"; sleep 0.8

hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = false})" >/dev/null 2>&1; sleep 1.2
for m in $(hyprctl monitors all -j | python3 -c "
import json,sys
print(' '.join(m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')))"); do
    hyprctl output remove "$m" >/dev/null 2>&1; sleep 0.4
done
sleep 1
hyprctl output create headless >/dev/null 2>&1; sleep 1.5
HL=$(hyprctl monitors all -j | python3 -c "
import json,sys
hs=[m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')]
print(hs[0] if len(hs)==1 else '')")
[ -n "$HL" ] || { echo "ABORT: expected exactly one headless output"; exit 1; }
hyprctl eval "return hl.monitor({output = [[$HL]], mode = [[2560x1600@60]], position = [[0x0]], scale = 1})" >/dev/null 2>&1; sleep 1.2
hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = true})" >/dev/null 2>&1; sleep 1.5

read -r MON W H <<< "$(hyprctl monitors -j | python3 -c "
import json,sys
m=json.load(sys.stdin)[0]; print(m['name'], m['width'], m['height'])")"
echo "monitor: $MON ${W}x${H}"
case "$MON" in HEADLESS*) ;; *) echo "ABORT: expected the headless output, got $MON"; exit 1 ;; esac

cfg "autohide=false, show_favorites=false, show_apps_button=false, show_trash=false, show_mounts=false"
sleep 0.8

dsp "hl.dsp.focus({monitor = \"$MON\"})"; sleep 0.3
dsp "hl.dsp.focus({workspace = $WS_HOME})"; sleep 0.4
setsid kitty -c NONE --class Z2A --title Z2AWIN -o background='#ff00ff' -o background_opacity=1.0 \
    -o confirm_os_window_close=0 --hold sh -c 'clear; sleep infinity' >/dev/null 2>&1 </dev/null &
sleep 3

ADDR=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='Z2A'), ''))")
[ -n "$ADDR" ] || { echo "ABORT: Z2A did not appear"; exit 1; }

dsp "hl.dsp.window.move({workspace = $WS_AWAY, window = [[address:$ADDR]], follow = false})"
sleep 1.2
[ "$(act)" = "$WS_HOME" ] || { echo "ABORT: the move took the view with it"; exit 1; }

# A FOCUS SINK on the home desktop. Without it `activewindow` still names Z2A
# after the move -- it was focused when it was spawned and moving it away does
# not hand focus to anything else -- so "Z2A is focused" was true before a
# single click and the control could not fail. Measured on the baseline run.
setsid kitty -c NONE --class Z2B --title Z2BWIN -o background='#204020' -o background_opacity=1.0 \
    -o confirm_os_window_close=0 --hold sh -c 'clear; sleep infinity' >/dev/null 2>&1 </dev/null &
sleep 3
SINK=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='Z2B'), ''))")
[ -n "$SINK" ] || { echo "ABORT: the focus sink did not appear"; exit 1; }
dsp "hl.dsp.focus({window = [[address:$SINK]]})"; sleep 0.8
[ "$(focused)" = "$SINK" ] || { echo "ABORT: focus is on $(focused), not the sink $SINK"; exit 1; }
echo "Z2A $ADDR parked on ws $WS_AWAY; standing on ws $WS_HOME, focus on sink $SINK"

read -r IX IY <<< "$(hyprctl clients -j | python3 /mnt/host/x47_cell.py Z2A)"
read -r PX PY PW PH <<< "$(hyprctl clients -j | python3 /mnt/host/x47_cell.py panel)"
CX=$(( PX + PW / 2 )); CY=$(( PY + PH / 2 ))
echo "icon=$IX,$IY  panel=$PX,$PY ${PW}x${PH}  cell centre=$CX,$CY"

raise() {   # hover the icon, then slide INTO the plate -- Y1's whole point
    warp $IX $IY; sleep 0.8
    warp $CX $CY; sleep 0.7
}

PARKX=$((W - 60)); PARKY=60

# ============ CONTROL: same height, well clear of the plate ============
ov on; sleep 2.5
raise
# 420px left of the plate's left edge is off the panel and off the pill, which
# only ever spans the icons themselves in this fixture.
OFFX=$(( PX - 420 ))
[ $OFFX -gt 20 ] || OFFX=40
warp $OFFX $CY; sleep 0.6
click; sleep 1.4
CTRL_WS=$(act); CTRL_WIN=$(focused)
echo "control click at $OFFX,$CY -> ws=$CTRL_WS focused=$CTRL_WIN"

# ============ THE CLICK ON THE PREVIEW ============
# Back to the same starting state the control began from, focus sink included,
# so the two clicks differ in NOTHING but where they land.
dsp "hl.dsp.focus({workspace = $WS_HOME})"; sleep 1.0
dsp "hl.dsp.focus({window = [[address:$SINK]]})"; sleep 0.8
[ "$(focused)" = "$SINK" ] || { echo "ABORT: could not re-arm the focus sink"; exit 1; }
ov on; sleep 2.2
raise
read -r QX QY <<< "$(hyprctl cursorpos | tr -d ',')"
[ "$(( QX > CX - 8 && QX < CX + 8 && QY > CY - 8 && QY < CY + 8 ))" = 1 ] \
    || { echo "ABORT: pointer is at $QX,$QY, not on the cell at $CX,$CY"; exit 1; }
grim -g "0,$((PY - 24)) ${W}x$((PH + 24))" "$OUT/$TAG-onpanel.png" 2>/dev/null
click; sleep 1.8
HIT_WS=$(act); HIT_WIN=$(focused)
echo "preview click at $CX,$CY -> ws=$HIT_WS focused=$HIT_WIN"

echo
echo "expected: ws=$WS_AWAY focused=$ADDR"
FAILED=0
[ "$CTRL_WIN" = "$ADDR" ] && { echo "CONTROL BROKEN: a click off the plate activated Z2A anyway"; FAILED=1; }
[ "$HIT_WS" = "$WS_AWAY" ] || { echo "MISS: the view did not go to ws $WS_AWAY"; FAILED=1; }
[ "$HIT_WIN" = "$ADDR" ]   || { echo "MISS: Z2A is not the focused window"; FAILED=1; }

[ $FAILED = 0 ] && echo "Z2 PASS -- clicking the preview goes to that window" \
                || echo "Z2 FAIL"
echo Z2_RIG_DONE
exit $FAILED
