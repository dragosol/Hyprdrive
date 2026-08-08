#!/bin/bash
# X24. Click a dock icon and prove the window SHRINKS INTO the pill instead of
# teleporting. Runs IN THE GUEST, coordinates come from the host off a frame of
# this same run.
#   x24_click.sh <iconX> <iconY>       -- overview already open, icon measured
#   x24_click.sh setup                 -- fixture + overview + control frame
#
# The flight is stretched to MS=2400 for the capture only: grim costs ~335ms a
# frame here, so at the shipping 220ms every sample would land after the window
# had already arrived and the rig would report a teleport for a rig reason. The
# duration is a config key precisely so a rig can do this without a rebuild; the
# gate asserts the SHIPPING default separately.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
OUT=/mnt/host/x24
MS=${MS:-2400}   # MS=0 is the negative control: teleport, and the gate must fail

# ov() comes from rig.sh; RIG_MON is set when the wrapper runs this headless,
# standalone runs keep the old Virtual-1 target.

if [ "$1" = setup ]; then
    hyprwall_pause
    pkill kitty; sleep 1.0
    hyprctl dispatch "hl.dsp.focus({workspace = 1})" >/dev/null; sleep 0.5

    # One fixture is solid pure green, so the largest green blob in any frame is
    # unambiguously the thing being animated. The second is grey and exists only
    # to give the pill a second slot: the shared icon-target helper takes a
    # quarter of the pill's width, which is the first of two equal slots.
    # setsid, or the fixture is a child of this ssh session and dies with it.
    setsid -f kitty --class x24fix --override background=#00ff00 sh -c 'sleep 3600' </dev/null >/dev/null 2>&1
    sleep 1.5
    setsid -f kitty --class x24other --override background=#303030 sh -c 'sleep 3600' </dev/null >/dev/null 2>&1
    sleep 1.5
    # kitty's remember_window_size makes each spawn inherit the last one's size,
    # so placement is explicit or an earlier rig's geometry leaks into this one.
    hyprctl eval "$(cat <<'LUA'
local want = { x24fix = {200, 200, 900, 600}, x24other = {1300, 300, 900, 600} }
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
    sleep 0.5

    # Record the SHIPPING duration before overriding it, and put it back at the
    # end of the run rather than hard-coding it here -- otherwise the second run
    # in a compositor session would read the rig's own leftover as "the default".
    hyprctl getoption plugin:scrolloverview:dock:minimize_ms | awk '/^int:/ {print $2}' > $OUT/default_ms.txt
    hyprctl eval "return hl.plugin.scrolloverview.configure({dock = {minimize_ms = $MS}})" >/dev/null
    ov on; sleep 1.5
    for _ in $(seq 20); do ydotool key 14:1 14:0; done; sleep 0.5
    grim -o "${RIG_MON:-Virtual-1}" $OUT/open.png
    echo "setup ms=$MS"
    exit
fi

# Coordinates are SCREEN px; rig.sh's warp() owns the ydotool halving.
warp $1 $2; sleep 0.4

# The control frame is shot with the pointer already parked on the icon, so the
# tile it measures is the tile the flight actually starts from -- hover ease and
# all.
grim -o "${RIG_MON:-Virtual-1}" $OUT/pre.png

ydotool click 0xC0
# 0.15s of lead. The stash and the first flight frame are not the same frame --
# a just-stashed window needs one commit before it draws again -- so a capture
# fired the instant the click lands can catch the gap and read as a teleport.
# 0.15s of a 2400ms flight is t=0.06, which the cubic has barely moved.
sleep 0.15
for i in 1 2 3 4 5; do grim -o "${RIG_MON:-Virtual-1}" $OUT/fly$i.png; done
sleep 2.0
grim -o "${RIG_MON:-Virtual-1}" $OUT/landed.png
hyprctl clients -j > $OUT/clients.json
hyprctl eval "return hl.plugin.scrolloverview.configure({dock = {minimize_ms = $(cat $OUT/default_ms.txt)}})" >/dev/null
echo "clicked $1,$2"
