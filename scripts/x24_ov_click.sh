#!/usr/bin/env bash
# X24 dock-side, overview half. Runs IN THE GUEST.
#
# Clicking the pinned dock while the overview is open must minimize the app AND
# leave the overview open. The second half needs a pixel check because there is
# no IPC for "is the overview open" -- and it needs a control on BOTH sides,
# because a single frame cannot tell you which state it is in.
#
#   ovopen.png   overview open, nothing clicked   <- control A
#   desktop.png  overview closed                  <- control B
#   post.png     overview open, dock icon clicked <- the measured frame
#
# post.png must land nearer control A than control B. Identical controls mean
# the capture stalled, and the gate fails rather than scoring that as a pass.
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/x24d
CLS=${1:-X24SOLO}

ov() { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }

ov off; sleep 1.5
grim -o Virtual-1 $OUT/desktop.png

ov on;  sleep 2.5
grim -o Virtual-1 $OUT/ovopen.png

hyprctl clients -j      > $OUT/pre-clients.json
hyprctl activewindow -j > $OUT/pre-active.json

# Same cell prediction as the desktop rig -- the pill does not move when the
# overview opens, which is itself part of what this proves.
read -r CX CY <<< "$(hyprctl clients -j | python3 /mnt/host/x24_cell.py "$CLS")"

mv2() { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; }
mv2 $CX $CY; sleep 0.5
ydotool click 0x40
for d in 2 -2 3 -1 0; do mv2 $((CX+d)) $((CY-d)); sleep 0.025; done
ydotool click 0x80
sleep 2.0

hyprctl clients -j      > $OUT/post-clients.json
hyprctl activewindow -j > $OUT/post-active.json
grim -o Virtual-1 $OUT/post.png

ov off
echo "OV_CLICKED $CLS at $CX,$CY"
