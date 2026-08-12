#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC Y9, as the user revised it 2026-08-06: "let's make those
# minimized windows only show in overview when filtered, otherwise they still
# don't show."
#
# Commit 50197ec proved the FIRST half (no query -> gone) and left the second
# explicitly unproven, calling it the next thing to do: typing a matching query
# must bring the minimized window BACK. Until that holds, a minimized window is
# unreachable from the overview, which is worse than where the user started.
#
# THREE STATES, one fixture set, one output, so the same wallpaper sits behind
# each and the numbers are comparable:
#
#   q0  overview, no query        magenta ABSENT   green present
#   q1  overview, "MAGWIN" typed  magenta PRESENT  green reduced
#   q2  query cleared             magenta ABSENT   green present again
#
# q2 is not decoration. Without it, a build that simply showed minimized windows
# always would pass q1, and that is the exact behaviour the user asked to be
# narrowed (00dbba9 -> 50197ec).
#
# GREEN IS THE LIVENESS CONTROL. It must not match "MAGWIN", so if the query
# never reaches the search bar green does not change either -- which is how
# 50197ec's run failed, and it is a rig fault that reads exactly like a product
# fault unless something else in the frame is watching for it.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1

TAG=${1:?usage: y9_rig.sh <tag>}
OUT=/mnt/host/y9; mkdir -p $OUT

mini() { dsp "hl.plugin.$RIG_NS.minimize($1)"; }

restore() {
    ov off
    mini "[[restore]]"
    headless_off
    hyprwall_resume
}
trap restore EXIT

hyprwall_pause

ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5
dsp "hl.dsp.focus({workspace = 1})"; sleep 0.8

RIG_HEADLESS_MODE=2560x1600@60      # this gate was proven at @60 [rig.sh header note]
headless_on || exit 1
trap restore EXIT                   # re-chain: headless_on installed its own EXIT trap

MON=$RIG_MON W=$RIG_W H=$RIG_H
echo "monitor: $MON ${W}x${H}"

dsp "hl.dsp.focus({monitor = \"$MON\"})"; sleep 0.3
setsid kitty -c NONE --class Y9GRN --title GRNWIN -o background='#00c000' -o background_opacity=1.0 \
    -o font_size=40 -o confirm_os_window_close=0 --hold sh -c 'clear; sleep infinity' >/dev/null 2>&1 </dev/null &
sleep 2.6
setsid kitty -c NONE --class Y9MAG --title MAGWIN -o background='#ff00ff' -o background_opacity=1.0 \
    -o font_size=40 -o confirm_os_window_close=0 --hold sh -c 'clear; sleep infinity' >/dev/null 2>&1 </dev/null &
sleep 2.6

MAG=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='Y9MAG'), ''))")
[ -n "$MAG" ] || { echo "ABORT: Y9MAG did not appear"; exit 1; }

# PLACE THEM. Every window in this session floats, so two windows spawned back
# to back are put wherever the compositor's float placement decides, and that is
# not a constant: on 2026-08-12 the pair landed EXACTLY stacked -- magenta over
# green, same 180 rows, green 0 px on the desktop frame -- and the gate reported
# "fixture was visible on the desktop: NO -- rig fault". Correctly, but only in
# one of two back-to-back suite runs, which is a straddler.
#
# Side by side with a gutter, on the only output there is (headless at 0x0,
# Virtual-1 disabled, so monitor coordinates are global ones), and read back:
# a placement that did not land is the same class of silent failure as a warp
# that did not land.
place() { # place CLASS X Y W H
    hyprctl eval "$(cat <<LUA
for _, w in ipairs(hl.get_windows()) do
    if w.class == "$1" then
        hl.dispatch(hl.dsp.focus({window = w}))
        hl.dispatch(hl.dsp.window.resize({x = $4, y = $5, relative = false}))
        hl.dispatch(hl.dsp.window.move({x = $2, y = $3, relative = false}))
    end
end
return 1
LUA
)" >/dev/null 2>&1
    sleep 0.8
}
place Y9GRN 200 350 1000 700
place Y9MAG 1360 350 1000 700

hyprctl clients -j | python3 -c "
import json,sys
want = {'Y9GRN': (200, 350, 1000, 700), 'Y9MAG': (1360, 350, 1000, 700)}
got = {c['class']: (c['at'][0], c['at'][1], c['size'][0], c['size'][1])
       for c in json.load(sys.stdin) if c.get('class') in want}
bad = 0
for k, w in want.items():
    g = got.get(k)
    print('    %-6s at %s size %s' % (k, g[:2] if g else '?', g[2:] if g else '?'))
    if g is None or max(abs(a - b) for a, b in zip(g, w)) > 8:
        print('ABORT: %s is at %s, the rig placed it at %s' % (k, g, w)); bad = 1
a, b = got.get('Y9GRN'), got.get('Y9MAG')
if a and b and not (a[0] + a[2] <= b[0] or b[0] + b[2] <= a[0]):
    print('ABORT: the two fixtures overlap -- the desktop baseline cannot see both'); bad = 1
sys.exit(bad)" || exit 1

# Both on screen first: the baseline that says the magenta CAN be seen at all.
grim -o $MON $OUT/$TAG-desktop.png

dsp "hl.dsp.focus({window = [[address:$MAG]]})"; sleep 0.6
mini ""
sleep 2.0
grim -o $MON $OUT/$TAG-minimized.png

ov on; sleep 3
grim -o $MON $OUT/$TAG-q0.png

ydotool type "MAGWIN" >/dev/null 2>&1
sleep 3
grim -o $MON $OUT/$TAG-q1.png

# Clear it a character at a time -- Escape closes the overview on this build,
# which would end the run rather than clear the query.
for i in 1 2 3 4 5 6; do ydotool key 14:1 14:0 >/dev/null 2>&1; sleep 0.12; done
sleep 3
grim -o $MON $OUT/$TAG-q2.png

echo "frames: $(ls $OUT/$TAG-*.png | wc -l)"
echo Y9_RIG_OK
