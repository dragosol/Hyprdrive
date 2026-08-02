#!/usr/bin/env bash
# usage: x43_click.sh GX GY     -- open the overview, click that tile, close.
#
# The press is HELD ~120ms and jitters, because a rig that presses and releases
# in the same instant never exercises the real path (that is how X16 was scored
# fixed while broken). The jitter is deliberately kept UNDER the 10px
# drag_threshold: this is a click test, not a drag test -- cross the threshold
# and you are measuring beginWindowDrag instead.
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/x43
GX=$1; GY=$2
MON=$(hyprctl monitors -j | python3 -c "
import json,sys
print(next((m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')), ''))")

ov()  { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }
mv2() { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; }

ov off; sleep 1.2
hyprctl activewindow -j > $OUT/click-active-pre.json
ov on;  sleep 3

mv2 $GX $GY; sleep 0.4
ydotool click 0x40            # press, no release
for d in 2 -2 3 -1 0; do mv2 $((GX+d)) $((GY-d)); sleep 0.025; done
ydotool click 0x80            # release
sleep 3

hyprctl activewindow -j > $OUT/click-active-post.json
hyprctl clients -j      > $OUT/click-clients-post.json
grim -o $MON $OUT/post.png

# The focus lines below are CONTEXT, NOT THE ASSERTION, and they are
# confounded: the overview closes with the cursor still parked on the tile's
# screen position, so focus_follows_mouse gets a say afterwards. Clicking the
# TOP tile can therefore print FOCUS_AFTER=X43BOT while the stacking is
# perfectly correct. Judge X43 with x43_gate.py on post.png -- pixels only.
python3 - <<'EOF'
import json
pre  = json.load(open('/mnt/host/x43/click-active-pre.json'))
post = json.load(open('/mnt/host/x43/click-active-post.json'))
print('FOCUS_BEFORE=%s' % pre.get('class'))
print('FOCUS_AFTER =%s (context only -- see note above)' % post.get('class'))
EOF
echo X43_CLICK_DONE
