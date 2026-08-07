#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC §13.14 Y12(b) — "It's still not identical to the hyprland
# blur on windows and that same blur on windows in overview, but I can't figure
# it out."
#
# 7afcf63 closed Y12(a) and wrote down what it deliberately did NOT close, plus
# a hypothesis it could not test: "the pass count was never the difference and
# the next fire should not go looking there again... a window's frost is tinted
# by the app's own surface at window_opacity 0.90, while the dock lays a flat
# background_color at dock:background_opacity over its blur."
#
# THE MEASUREMENT PROBLEM that hypothesis creates: blur RADIUS and TINT are
# confounded. Both make a plate show less of what is behind it, and a variance,
# contrast or "how different from the backdrop" reading cannot separate them.
# So this backdrop carries TWO SPATIAL FREQUENCIES side by side -- fine vertical
# bars on the left half of the screen, coarse ones on the right.
#
#   TINT   attenuates both frequencies by the same factor.
#   BLUR   attenuates the fine one far more than the coarse one.
#
# The RATIO fine/coarse is therefore a blur-radius measure independent of tint,
# and the coarse level against the raw backdrop recovers the tint separately.
# Two numbers instead of one, and they answer 7afcf63's question directly.
#
# Both plates frost the SAME backdrop in the SAME frame: the translucent test
# window sits directly above the pill and spans the same columns, so it crosses
# the fine/coarse boundary exactly as the pill does.
#
# The headless swap works here. 7afcf63 recorded that it "stops the overview
# opening at all", which was true that afternoon and is not true now -- every rig
# this session (z1, z3, y9, y11) opens the overview on a headless output.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)

TAG=${1:?usage: y12b_rig.sh <tag>}
OUT=/mnt/host/y12b; mkdir -p $OUT

dsp()  { hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }
ov()   { dsp "hl.plugin.scrolloverview.overview([[$1]])"; }
cfg()  { hyprctl eval "hl.config({plugin={scrolloverview={dock={$1}}}}) return 0" >/dev/null 2>&1; }

restore() {
    ov off
    cfg "autohide=true, show_favorites=true, show_apps_button=true, show_trash=true"
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
systemd-run --user --on-active=90min systemctl --user start hyprwall.timer >/dev/null 2>&1

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5
dsp "hl.dsp.focus({workspace = 1})"; sleep 0.8

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

# Favourites ON: the user's real dock, and a wide pill is what gives the coarse
# bars room to be counted. Nothing here predicts the pill's box -- the gate finds
# it from the frost itself.
cfg "autohide=false, show_favorites=true, show_apps_button=true, show_trash=true"
sleep 0.6

# THE BACKDROP. Opaque, fullscreen, and the only thing behind either plate.
# Fine bars (one cell) on the left half, coarse bars (eight cells) on the right.
dsp "hl.dsp.focus({monitor = \"$MON\"})"; sleep 0.3
# REDRAWN IN A LOOP, not printed once. The first cut drew the bars, then the rig
# resized the window to the whole output -- and the bars stayed the size of the
# terminal that had printed them, leaving the wallpaper showing through
# everywhere the plates actually sit. Redrawing means the pattern always fills
# whatever kitty has been resized to, whatever order things happen in.
setsid kitty -c NONE --class Y12BG --title Y12BG -o background='#000000' -o background_opacity=1.0 \
    -o font_size=8 -o confirm_os_window_close=0 --hold sh -c '
      while :; do
        cols=$(tput cols); rows=$(tput lines); q=$((cols/4)); line=""; i=0
        while [ $i -lt $cols ]; do
            z=$(( i / q )); [ $z -gt 3 ] && z=3
            case $z in 0) b=1 ;; 1) b=3 ;; 2) b=8 ;; *) b=16 ;; esac
            blk=$(( (i / b) % 2 ))
            if [ $blk = 0 ]; then line="$line\033[107m "; else line="$line\033[40m "; fi
            i=$((i+1))
        done
        printf "\033[H"; j=0
        while [ $j -lt $rows ]; do printf "$line\033[0m\n"; j=$((j+1)); done
        sleep 2
      done' >/dev/null 2>&1 </dev/null &
sleep 4.5

BG=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='Y12BG'), ''))")
[ -n "$BG" ] || { echo "ABORT: backdrop did not appear"; exit 1; }
dsp "hl.dsp.focus({window = [[address:$BG]]})"; sleep 0.4
dsp "hl.dsp.window.resize({exact=true,x=$W,y=$H})"; sleep 0.6
dsp "hl.dsp.window.move({x=0,y=0,exact=true})"; sleep 1.0

# THE TEST WINDOW. Translucent so Hyprland frosts the backdrop behind it -- an
# OPAQUE app defeats compositor blur outright, which is the standing rule.
# Straddles the screen's midline so it crosses the fine/coarse boundary, and
# sits above the pill so both plates see the same columns.
TWX=640; TWW=1280; TWH=240; TWY=$(( H - 420 ))
setsid kitty -c NONE --class Y12WIN --title Y12WIN -o background='#101010' -o background_opacity=0.5 \
    -o confirm_os_window_close=0 --hold sh -c 'clear; sleep infinity' >/dev/null 2>&1 </dev/null &
sleep 3
TW=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='Y12WIN'), ''))")
[ -n "$TW" ] || { echo "ABORT: test window did not appear"; exit 1; }
dsp "hl.dsp.focus({window = [[address:$TW]]})"; sleep 0.4
dsp "hl.dsp.window.resize({exact=true,x=$TWW,y=$TWH})"; sleep 0.6
dsp "hl.dsp.window.move({x=$TWX,y=$TWY,exact=true})"; sleep 1.2

AT=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((str(c['at'])+' '+str(c['size']) for c in json.load(sys.stdin) if c['class']=='Y12WIN'), '?'))")
echo "test window at $AT (wanted [$TWX, $TWY] [$TWW, $TWH])"
echo "$TWX $TWY $TWW $TWH" > $OUT/$TAG-win.txt

# Pointer far away: a hover highlight inside the pill is not backdrop.
ydotool mousemove -a -x $(( (W - 80) / 2 )) -y 20 2>/dev/null
sleep 1.5

grim -o $MON $OUT/$TAG-desktop.png
ov on; sleep 3.5
grim -o $MON $OUT/$TAG-overview.png
ov off; sleep 1.5

echo Y12B_RIG_OK
