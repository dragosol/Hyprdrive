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
    hyprctl getoption $RIG_KEY:dock:minimize_ms | awk '/^int:/ {print $2}' > $OUT/default_ms.txt
    hyprctl eval "return hl.plugin.$RIG_NS.configure({dock = {minimize_ms = $MS}})" >/dev/null

    # THE STRETCH COMES FROM anim_scale, NOT FROM minimize_ms. Measured
    # 2026-08-12 on 7b32fd6 (zrig/danglingA/x24probe{B,C,D}/): with
    # dock:minimize_ms set to 2000 and read back as 2000 -- through
    # hl.plugin.hyprdrive.configure AND through hl.config, both -- the flight is
    # over inside 0.37 s, i.e. it still runs at the 400 ms default. With
    # anim_scale 8 and the same key at 400 it runs 2.9 s, which is 400x8. The
    # key is registered, readable and ignored by flightProgress at runtime;
    # that is a plugin defect and it is ticketed
    # (zrig/danglingA/tickets/x24_minimize_ms.md). Until it is fixed the only
    # working slow-motion is anim_scale, and anim_slow READS IT BACK.
    anim_slow "${X24_ANIM:-8}" || { echo "ABORT: anim_scale did not take"; exit 1; }
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

# GET THE POINTER OFF THE ICON. It is parked there for the click, and an icon
# under the pointer raises the X47 hover preview panel -- a 196x132 framed
# thumbnail of the very window that is flying, sitting just above the pill.
# largest_green then finds the PANEL in every frame instead of the proxy, and
# the gate reads five identical 196px boxes at a fixed y and reports a teleport.
# Measured 2026-08-12: fly1..fly5 and landed all came back 196x132 at 1148,1364,
# which is the panel's rectangle and not any part of the flight. The panel's
# grace is 120ms (x47 GRACE), so it is gone before the first frame.
warp 80 80
sleep 0.05
echo "pointer parked at $(hyprctl cursorpos)"

# 0.25s of lead. The stash and the first flight frame are not the same frame --
# a just-stashed window needs one commit before it draws again -- so a capture
# fired the instant the click lands can catch the gap and read as a teleport.
# It is also what the hover panel's 120ms grace needs to expire in.
# 0.25s of a 2400ms flight is t=0.10, which the cubic has barely moved.
sleep 0.25
# Eight frames, not five: a whole-output grim costs ~0.36s here, so five of them
# cover 1.8s of a flight that is 400ms x anim_scale = 3.2s long.
for i in 1 2 3 4 5 6 7 8; do grim -o "${RIG_MON:-Virtual-1}" $OUT/fly$i.png; done
sleep 2.0
grim -o "${RIG_MON:-Virtual-1}" $OUT/landed.png
anim_restore
hyprctl clients -j > $OUT/clients.json
# The dock's hover preview panel is held out for the whole flight and shows a
# thumbnail of the window in flight; predict its rectangle so the gate can take
# it out of the green search. x47_cell.py models the same classes-only dock this
# gate configures.
# x47_cell.py's panel x is the PILL's left edge, and the panel is centred on the
# ICON it rose from -- x47_frost.py's plate_rect() records the same 190px error.
# The icon x is the coordinate this script was just handed, so recentre on it and
# pad 12px so the plate's border and shadow come out with it.
hyprctl clients -j | python3 "$(dirname "$0")/x47_cell.py" panel 2>/dev/null \
    | awk -v cx="$1" '{ printf "%d %d %d %d\n", cx - $3/2 - 12, $2 - 12, $3 + 24, $4 + 24 }' \
    > $OUT/panel.txt || : > $OUT/panel.txt
hyprctl eval "return hl.plugin.$RIG_NS.configure({dock = {minimize_ms = $(cat $OUT/default_ms.txt)}})" >/dev/null
echo "clicked $1,$2"
