#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC 13.9 X28 fixture. Runs IN THE GUEST.
#
# Two dock classes with different capabilities, because the menu's content
# depends on whether a desktop entry claims the class:
#   kitty     -- a real entry, so it has an id: Show Details and the favourites
#                toggle have something to act on.
#   X28QUIT   -- two windows of a synthetic class nothing claims, so Quit can be
#                fired at it without taking the favourites fixture down too.
#
# Headless output, Virtual-1 disabled: Virtual-1 draws ~1fps with no viewer
# attached and every capture in this rig would be a stale frame.
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/x28; mkdir -p $OUT

ov() { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }
dsp() { hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }

systemctl --user stop hyprwall.timer 2>/dev/null
systemd-run --user --on-active=30min systemctl --user start hyprwall.timer >/dev/null 2>&1

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5

hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = false})" >/dev/null 2>&1; sleep 1.2
for m in $(hyprctl monitors all -j | python3 -c "
import json,sys
print(' '.join(m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')))"); do
    hyprctl output remove "$m" >/dev/null 2>&1; sleep 0.4
done
sleep 1
hyprctl output create headless >/dev/null 2>&1; sleep 1.5
MON=$(hyprctl monitors -j | python3 -c "
import json,sys
hs=[m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')]
print(hs[0] if len(hs)==1 else '')")
[ -n "$MON" ] || { echo "ABORT: expected exactly one headless output"; exit 1; }
hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = true})" >/dev/null 2>&1; sleep 1.5

hyprctl monitors -j | python3 -c "
import json,sys
m=json.load(sys.stdin)[0]; print('MON %s %d %d' % (m['name'], m['width'], m['height']))" > $OUT/monitor.txt
cat $OUT/monitor.txt

# The favourites store starts empty, or the toggle's direction is unknowable.
rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/scrolloverview/favorites"

spawn() { # class
    dsp "hl.dsp.focus({monitor = \"$MON\"})"; sleep 0.15
    if [ "$1" = kitty ]; then
        setsid kitty -c NONE -o background='#202030' -o background_opacity=1.0 \
            -o confirm_os_window_close=0 --hold sh -c 'clear' >/dev/null 2>&1 </dev/null &
    else
        setsid kitty -c NONE --class "$1" -o background='#303020' -o background_opacity=1.0 \
            -o confirm_os_window_close=0 --hold sh -c 'clear' >/dev/null 2>&1 </dev/null &
    fi
    sleep 2.2
}

spawn kitty
spawn X28QUIT
spawn X28QUIT

sleep 1.5
hyprctl clients -j > $OUT/fixture-clients.json
python3 -c "
import json
for c in json.load(open('$OUT/fixture-clients.json')):
    if c['class'] in ('kitty','X28QUIT'):
        print(' ', c['class'], c['address'], c['workspace']['name'])
"

ov off; sleep 1.2
ov on;  sleep 3
grim -o $MON $OUT/base.png
echo X28_FIXTURE_OK
