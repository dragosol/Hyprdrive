#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC §13.14 Y8 — "Once I drop the window on the dock (to
# minimize), the app icon it minimized to bounces ONCE (kind of like in macos,
# same animation) to indicate it's there."
#
# ONE hop is the claim, and "not a decaying bounce train" is how the spec words
# the thing it must not be. That is a SHAPE over time, so this takes a burst of
# frames of the strip directly above the pill and hands the host the series.
#
# anim_scale, not a faster camera. The bounce is 420ms at BOUNCE_MS and grim
# cannot be trusted to catch a shape that short; the dock funnels every timed
# thing through elapsedMs, which divides by plugin:scrolloverview:anim_scale, so
# scaling once slows the flight AND the bounce together and the shape is
# unchanged. Restored on the way out.
#
# usage: y8_probe.sh <grabX> <grabY> <pillCentreX> <pillCentreY> <pillTop>
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/y8; mkdir -p $OUT; rm -f $OUT/f*.png

GX=$1; GY=$2; PX=$3; PY=$4; PTOP=$5
SCALE=${Y8_SCALE:-8}
FRAMES=${Y8_FRAMES:-50}
GAP=${Y8_GAP:-0.20}

read -r MON W H <<< "$(hyprctl monitors -j | python3 -c "
import json,sys
m=json.load(sys.stdin)[0]; print(m['name'], m['width'], m['height'])")"
cfg()  { hyprctl eval "hl.config({plugin={scrolloverview={dock={$1}}}}) return 0" >/dev/null 2>&1; }
anim() { hyprctl eval "hl.config({plugin={scrolloverview={anim_scale=$1}}}) return 0" >/dev/null 2>&1; }

restore() { anim 1; cfg "autohide=true"; }
trap restore EXIT

cfg "autohide=false"; anim $SCALE; sleep 0.8
echo "anim_scale=$(hyprctl getoption plugin:scrolloverview:anim_scale | head -1)"

# THE PILL'S OWN ROWS, plus a little headroom. The first cut of this probe took
# the 48px strip ABOVE the pill and measured nothing at all across 60 frames:
# BOUNCE_HEIGHT is 0.34 of an icon, about 18px, and the icon starts ~14px inside
# the plate, so almost the whole hop happens INSIDE the pill. A band that only
# watched the air above it could not see the animation it was gating.
BAND="0,$((PTOP - 30)) ${W}x$(( H - PTOP + 30 ))"
echo "band: $BAND"

mv2()  { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; }
walk() { local n=12 i; for i in $(seq 1 $n); do
    mv2 $(( $1 + ($3 - $1) * i / n )) $(( $2 + ($4 - $2) * i / n )); sleep 0.05; done; }

# WHOLE-OUTPUT GRABS, cropped on the host. `grim -g <region>` was measured to
# hand back one frozen frame for ten seconds straight on this guest while
# `grim -o <output>` over the same span showed 467017 changed pixels -- so a
# region grab is not a cheaper whole-screen grab here, it is a different and
# untrustworthy capture path. Every "nothing animated" reading this probe
# produced before the switch was a reading of grim.
mv2 $((W - 60)) 60; sleep 1.2
grim -o $MON $OUT/base.png 2>/dev/null

mv2 $GX $GY; sleep 0.6
ydotool click 0x40; sleep 0.15
walk $GX $GY $PX $PY; sleep 0.5
ydotool click 0x80                     # release ON the pill: flight + bounce

# The bounce starts when the flight LANDS, i.e. minimize_ms * anim_scale after
# the release -- not at the release. A burst that stopped at the flight's end
# would photograph everything except the thing under test.
for i in $(seq 0 $((FRAMES - 1))); do
    grim -o $MON "$(printf "$OUT/f%02d.png" $i)" 2>/dev/null
    sleep $GAP
done

# Put the window back so the next rig starts from a normal desktop.
hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.minimize([[restore]]))" >/dev/null 2>&1
sleep 2
echo "frames: $(ls $OUT/f*.png | wc -l)"
echo Y8_PROBE_OK
