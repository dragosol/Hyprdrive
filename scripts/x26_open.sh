#!/bin/bash
# X26 phase 1. Runs IN THE GUEST. Builds the fixture and opens the overview, so
# the HOST can find the draggable tile by colour before phase 2 grabs it.
#
# The tile is never hard-coded: overview layout moves with window count, scale
# and workspace, and a stale coordinate produces a drag that grabs nothing and
# a rig that reports "drop did not commit" for the wrong reason.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
OUT=/mnt/host/x26

clear_search() { for _ in $(seq 20); do ydotool key 14:1 14:0; done; sleep 0.5; }

hyprwall_pause
pkill kitty; sleep 1.0
hyprctl dispatch "hl.dsp.focus({workspace = 1})" >/dev/null; sleep 0.5

# Solid pure green: the proxy has to be findable as a blob in a screenshot.
# --override, not an OSC 11 escape: the escape raced kitty's startup and landed
# on a window that then rendered its normal background, which reads as "the tile
# is not on screen". The second window gives the dock a second icon.
# Every stray kitty goes first -- leftovers from earlier rigs change the running
# class count, which changes the pill's width, which moves its centre.
# setsid, because a plain `&` makes the fixture a child of the ssh session: it
# survived long enough to appear in this script's own screenshot and was gone by
# the time the next script connected, which reads as "the tile does not render".
setsid -f kitty --class x26fix --override background=#00ff00 sh -c 'sleep 3600' </dev/null >/dev/null 2>&1
sleep 1.5
setsid -f kitty --class x26other --override background=#303030 sh -c 'sleep 3600' </dev/null >/dev/null 2>&1
sleep 1.5

# Place the fixture explicitly. kitty has remember_window_size on by default,
# so ANY earlier rig that resized a kitty (x29_capture.sh does) changes the size
# every later fixture spawns at -- which moves the overview tile, the pill width
# and the grab point all at once. Do not inherit that.
hyprctl eval "$(cat <<'LUA'
local want = { x26fix = {200, 200, 900, 600}, x26other = {1300, 300, 900, 600} }
for _, w in ipairs(hl.get_windows()) do
    local p = want[w.class]
    if p then
        hl.dispatch(hl.dsp.focus({window = w}))
        hl.dispatch(hl.dsp.window.resize({x = p[3], y = p[4], relative = false}))
        hl.dispatch(hl.dsp.window.move({x = p[1], y = p[2], relative = false}))
    end
end
return 1
LUA
)" >/dev/null
sleep 1.0

# The dock the CELL PREDICTORS model: running classes and nothing else.
# x24_cell.py / x28_cell.py compute slot centres from the class list alone, and
# gate_slate leaves favourites, the Show Applications button and the trash ON --
# five slots where the predictor counts two. Measured 2026-08-12: the pill is
# then 362px wide at x1099 instead of 152px at x1204, and the click the rig
# believed was on the fixture's icon landed on the TRASH. gate_slate puts all of
# these back before the next gate, so turning them off here costs nothing.
cfg_dock "show_favorites=false, show_apps_button=false, show_trash=false, show_mounts=false"
sleep 0.6
opt_want $RIG_KEY:dock:show_apps_button false || { echo "ABORT: dock composition did not take"; exit 1; }

ov on; sleep 1.5
clear_search
grim -o Virtual-1 $OUT/open.png
hyprctl clients -j > $OUT/clients_pre.json
echo opened
