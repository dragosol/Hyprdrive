#!/usr/bin/env bash
# X43 fixture: TWO OVERLAPPING floating windows on ws1.
#
# X43 is a STACKING bug, so the fixture's whole job is to create an overlap
# whose top window is unambiguous in pixels. Every previous X43 acceptance test
# asserted FOCUS, which was already correct -- that is why it was closed three
# times while still broken.
#
#   BOT  #ff0000 red   1000x700 at (200,200)   spawned first  -> underneath
#   TOP  #0000ff blue  1000x700 at (600,420)   spawned second -> on top
#   overlap = x[600,1200] y[420,900]
#
# kitty, never foot (user standing rule): foot cannot be made opaque per-window
# the way -o background_opacity=1.0 does here, and a translucent fixture makes
# the overlap probe meaningless.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
OUT=/mnt/host/x43; mkdir -p $OUT

# ov()/dsp() come from lib/rig.sh (identical bodies lived here first).

hyprwall_pause
ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5

# Exactly one headless output, Virtual-1 off: a starved Virtual-1 stalls every
# output including headless (established by the X1 fixture). The swap itself is
# OWNED BY THE GATE WRAPPER (gates/x43_raise/run.sh, via rig.sh headless_on),
# because its EXIT-trap teardown must outlive this script -- x43_open.sh and
# x43_click.sh still need the headless after this one exits.
MON=$(hyprctl monitors -j | python3 -c "
import json,sys
print(next((m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')), ''))")
[ -n "$MON" ] || { echo "ABORT: no headless output up -- run via gates/x43_raise/run.sh"; exit 1; }
echo "output: $MON"

spawn() { # class colour ws w h x y
    dsp "hl.dsp.focus({monitor = \"$MON\"})"; sleep 0.15
    dsp "hl.dsp.focus({workspace = $3})"; sleep 0.2
    setsid kitty -c NONE --class "$1" -o background="$2" -o background_opacity=1.0 \
        -o confirm_os_window_close=0 --hold sh -c 'clear' >/dev/null 2>&1 </dev/null &
    sleep 2.2
    A=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='$1'), ''))")
    [ -n "$A" ] || { echo "ABORT: $1 did not appear"; exit 1; }
    dsp "hl.dsp.focus({ window = [[address:$A]] })"; sleep 0.3
    F=$(hyprctl activewindow -j | python3 -c "import json,sys;print(json.load(sys.stdin).get('floating'))")
    [ "$F" = "True" ] || { dsp "hl.dsp.window.float()"; sleep 0.5; }
    dsp "hl.dsp.window.resize({exact=true,x=$4,y=$5})"; sleep 0.5
    dsp "hl.dsp.window.move({exact=true,x=$6,y=$7})"; sleep 0.5
}

spawn X43BOT '#ff0000' 1 1000 700 200 200
spawn X43TOP '#0000ff' 1 1000 700 600 420

# A third window on ws2 so the desktop strip has more than one card and the
# overview is a realistic mission control rather than a degenerate one.
spawn X43OTH '#00ff00' 2 700 450 300 300

dsp 'hl.dsp.focus({workspace = 1})'; sleep 1.0
# TOP must be the one on top AND the focused one at rest, so that the click on
# BOT is a genuine "select a non-foreground window".
BOTA=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='X43BOT'), ''))")
TOPA=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='X43TOP'), ''))")
dsp "hl.dsp.focus({ window = [[address:$TOPA]] })"; sleep 0.4
dsp "hl.dsp.window.bring_to_top()"; sleep 0.6

echo "BOT=$BOTA"
echo "TOP=$TOPA"
printf '%s\n' "$BOTA" > $OUT/bot.addr
printf '%s\n' "$TOPA" > $OUT/top.addr

hyprctl clients -j    > $OUT/fixture-clients.json
hyprctl monitors -j   > $OUT/fixture-monitors.json
hyprctl activewindow -j > $OUT/fixture-active.json

python3 - <<'EOF'
import json
cs = json.load(open('/mnt/host/x43/fixture-clients.json'))
for c in cs:
    if c['class'].startswith('X43'):
        print('%-7s ws=%-3s float=%-5s at=%s size=%s' % (c['class'], c['workspace']['id'], c['floating'], c['at'], c['size']))
EOF

ov off; sleep 1.2
grim -o $MON $OUT/pre.png
echo X43_FIXTURE_OK
