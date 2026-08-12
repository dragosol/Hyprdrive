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

    # THE STRETCH COMES FROM minimize_ms, and it always did. The note that used
    # to sit here said the key was ignored and stretched with anim_scale
    # instead, on the strength of two probes that timed WHEN THE FIXTURE STOPPED
    # BEING GREEN -- which under EASE_OUT_EXPO is ~18% of the duration, not the
    # duration. Re-measured 2026-08-12 on 3d5281c off the plugin's own draw log
    # (zrig/danglingB/x24/ms-probe.log), through hl.config AND through
    # hl.plugin.hyprdrive.configure, fired by the minimize dispatcher AND by a
    # real dock click: 400 -> 415ms, 2000 -> 2056ms, 100 -> 109ms. The old
    # probe's own numbers say the same thing once read as a fade: 0.37s at
    # anim_scale 1 and 2.9s at anim_scale 8 are the same 18% of 2000ms and of
    # 2000x8ms.
    #
    # It still takes anim_scale ON TOP, and for a reason that has nothing to do
    # with the key working: EXPO fades the proxy as it flies, and the green
    # blob the gate hunts stops being green early. The mask wants G > 150; a
    # proxy at alpha `a` over this backdrop reads G ~ 225a + 30, so it is
    # findable only while a > 0.53, i.e. while easeOutExpo < 0.47, i.e. over the
    # first ~11% of ANY flight however long. Eight whole-output grims cost
    # ~0.36s each, so the camera needs 3.1s inside that first 11% -- ~29s of
    # flight to keep all eight, ~16s to keep five, and the gate needs three.
    # minimize_ms alone cannot get there: it is capped at 2000ms (Config.cpp).
    #
    # So the flight duration is set as high as the key allows and anim_scale
    # multiplies it up to a FIXED target, computed from what the key actually
    # reads back rather than assumed -- the day minimize_ms changes (X24 moved
    # the default 400 -> 220) this rig keeps filming the same 16 seconds.
    MS_EFF=$(hyprctl getoption $RIG_KEY:dock:minimize_ms | head -1 | awk '{print $2+0}')
    # MS=0 is the negative control -- no flight at all -- and there is nothing
    # to stretch; 1 keeps the arithmetic below defined and the scale at 1.
    [ "${MS_EFF:-0}" -gt 0 ] || MS_EFF=${X24_TARGET_MS:-9600}
    # 9600ms, and the window is narrow at both ends. The eight frames start
    # ~0.32s after the click and end ~1.83s after it, so the flight has to be
    # long enough that the FIRST is still within 25% of the tile (P2 -> D >
    # 7.8s) and short enough that the LAST has reached the pill's own columns
    # with its foot above the plate (P6 -> D < 10.7s). Both bounds are expo on
    # this fixture's geometry, measured 2026-08-12.
    ANIM=$(python3 -c "import math;print(max(1, math.ceil(${X24_TARGET_MS:-9600} / $MS_EFF)))")
    echo "stretch: minimize_ms readback ${MS_EFF}ms x anim_scale $ANIM = $((MS_EFF * ANIM))ms of flight"
    anim_slow "$ANIM" || { echo "ABORT: anim_scale did not take"; exit 1; }
    ov on; sleep 1.5
    for _ in $(seq 20); do ydotool key 14:1 14:0; done; sleep 0.5
    grim -o "${RIG_MON:-Virtual-1}" $OUT/open.png
    echo "setup ms=$MS"
    exit
fi

# Coordinates are SCREEN px; rig.sh's warp() owns the ydotool halving.
warp $1 $2; sleep 0.4

# The icon this run is aiming at, for P6. The gate used to ask whether the last
# measurable proxy was inside the PILL's columns, and that is unanswerable for a
# tall window: it shrinks toward a 54px icon, so its foot crosses the plate's top
# edge (which the same predicate requires it to stay above) while its centre is
# still 300px short of a one-slot pill's left edge -- measured 2026-08-12, the
# two halves want E >= 0.89 and E < 0.83 of the same frame. The flight's promise
# is X46's: it flies into THE APP'S OWN ICON. That is this coordinate, and
# progress toward it is what the frames can carry honestly.
printf '%s %s\n' "$1" "$2" > $OUT/icon.txt

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
# Ten frames, not five: a whole-output grim costs ~0.20s here, so five of them
# cover 1.0s of a 9.6s stretched flight and ten cover 2.0s -- far enough in that
# P6's last measurable proxy has covered ~79% of the way to the icon rather than
# the 72% eight frames reach, which is too close to its own floor to survive
# run-to-run jitter.
for i in 1 2 3 4 5 6 7 8 9 10; do grim -o "${RIG_MON:-Virtual-1}" $OUT/fly$i.png; done
sleep 2.0
grim -o "${RIG_MON:-Virtual-1}" $OUT/landed.png
# Nothing here stretches anim_scale any more, but an earlier rig that died mid-
# run can have left it stretched, and the frame budget above is arithmetic on a
# 2400ms flight. Put the clock back either way.
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
