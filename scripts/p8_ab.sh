#!/usr/bin/env bash
# Phase 8 A/B. Runs IN THE GUEST. Drives four window drags -- one that stays on
# its own card, one onto another desktop's strip cell, one that just misses the
# dock pill, and one onto it -- and records, for each:
#
#   * the settled frame (grim, on a headless output: Virtual-1 hands back stale
#     frames while no viewer is attached to the VM),
#   * every window's workspace/position/size afterwards, and
#   * the drop dump, if the build under test carries the temporary
#     instrumentation.
#
# THE DUMP NEEDS A TEMPORARY PATCH, exactly as scripts/attic/p7_ab.sh does.
# /tmp/p8drop.log is written by throwaway logging in renderDraggedWindow and in
# endWindowDrag's three gather stages -- the proxy box and both eased progresses
# once per drawn frame, then the 16 drop facts and the branch actually taken.
# It is deliberately NOT committed: it opens a file from the render path. The
# parent (a4189e2) carries the same dump computed from its own locals, which is
# what makes the two logs comparable line for line. Method and numbers:
# /mnt/host/zrig/phase8/AB_RESULT.md.
#
# Coordinates come from $OUTROOT/points, measured ONCE on the host off a setup
# frame and then reused by every run of every build -- a per-run measurement
# would let the two builds be driven differently, which is the one thing an A/B
# may not do. Run with `setup` first to produce that frame.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1

TAG=${1:?usage: p8_ab.sh <setup|TAG>}
OUTROOT=/mnt/host/zrig/phase8
mkdir -p "$OUTROOT"

# The rotation is HELD for the whole A/B, not per run. Measured the hard way on
# the first pass of this rig: hyprwall_resume at the end of a run re-arms the
# timer, and starting the timer is itself a rotation trigger, so run 2 came up
# on a different wallpaper and every frame comparison was measuring that -- a
# 1.5M px "difference" between two runs of the SAME build. Same mechanism
# suite.sh holds the timer across a whole suite for.
export RIG_HYPRWALL_HELD=1
hyprwall_pause 90min
headless_on || exit 1

# GREEN on desktop 1 is the window every leg drags. BLUE lives on desktop 2 so
# that desktop has a strip cell with something findable in it: the MOVE leg's
# drop target is that cell, and it is measured off the blue mini rather than
# predicted from the strip layout.
fixture() {
    killothers __none__ >/dev/null 2>&1
    pkill -9 kitty >/dev/null 2>&1
    sleep 1.0
    dsp "hl.dsp.focus({workspace = 2})"; sleep 0.4
    fixture_kitty p8blue 300 300 900 600 "#0000ff" || return 1
    dsp "hl.dsp.focus({workspace = 1})"; sleep 0.4
    fixture_kitty p8green 200 200 900 600 "#00ff00" || return 1
    sleep 0.6
    ov on
    sleep 2.0
}

# One drag: press on the tile, past the threshold, settle, travel, settle, drop.
# Same pacing as scripts/x26_drag.sh, whose numbers were tuned against this
# guest's capture rate.
drag() { # drag NAME GX GY TX TY
    local name=$1 gx=$2 gy=$3 tx=$4 ty=$5 i
    warp "$gx" "$gy"; sleep 0.5
    ydotool click 0x40
    sleep 0.3
    for i in $(seq 1 12); do warp $(( gx + (gx + 90 - gx) * i / 12 )) $(( gy + (gy + 60 - gy) * i / 12 )); sleep 0.05; done
    sleep 0.9
    grim -o "$RIG_MON" "$OUT/$name-home.png"
    for i in $(seq 1 12); do warp $(( gx + 90 + (tx - gx - 90) * i / 12 )) $(( gy + 60 + (ty - gy - 60) * i / 12 )); sleep 0.05; done
    warp "$tx" "$ty"
    sleep 1.2
    grim -o "$RIG_MON" "$OUT/$name-over.png"
    ydotool click 0x80
    sleep 1.8
    grim -o "$RIG_MON" "$OUT/$name-post.png"
    hyprctl clients -j > "$OUT/$name-clients.json"
    alive_or_die "after the $name drop"
}

if [ "$TAG" = setup ]; then
    OUT=$OUTROOT/setup
    rm -rf "$OUT"; mkdir -p "$OUT"
    fixture || exit 1
    sleep 1.0
    grim -o "$RIG_MON" "$OUT/open.png"
    hyprctl clients -j > "$OUT/clients.json"
    echo "P8_SETUP_OK $RIG_MON ${RIG_W}x${RIG_H}"
    exit 0
fi

[ -f "$OUTROOT/points" ] || { echo "p8_ab: no $OUTROOT/points -- run 'p8_ab.sh setup' and measure it on the host" >&2; exit 1; }
read -r GX GY MX MY PCX PTOP < "$OUTROOT/points"

OUT=$OUTROOT/$TAG
rm -rf "$OUT"; mkdir -p "$OUT"
echo "grab $GX,$GY  strip-cell-2 $MX,$MY  pill $PCX/$PTOP" | tee "$OUT/points.txt"

# Four legs, each on a fresh fixture so one leg's outcome cannot decide the
# next one's starting state.
for LEG in local move miss dock; do
    fixture || exit 1
    : > /tmp/p8drop.log
    case $LEG in
        local) drag local "$GX" "$GY" $(( GX + 250 )) $(( GY + 150 )) ;;
        move)  drag move  "$GX" "$GY" "$MX" "$MY" ;;
        miss)  drag miss  "$GX" "$GY" "$PCX" $(( PTOP - 28 )) ;;
        dock)  drag dock  "$GX" "$GY" "$PCX" $(( PTOP + 39 )) ;;
    esac
    cp /tmp/p8drop.log "$OUT/$LEG.dump" 2>/dev/null
    ov_off_settled
done

headless_off
hyprwall_resume
ls -la "$OUT" | tail -20
echo P8_AB_OK
