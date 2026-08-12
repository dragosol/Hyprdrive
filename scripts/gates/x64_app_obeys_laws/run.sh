#!/usr/bin/env bash
# x64_app_obeys_laws -- the settings app is held to the rules it edits.
#
# An app that configures the frost and the motion and then ships an opaque window
# with a linear fade is the funniest possible bug, so this gate points the
# product's own two standing rules back at it.
#
#   P1 FROST   the app's surface is translucent AND what shows through it is
#              BLURRED. Both halves matter and neither is enough: an opaque
#              window has no backdrop (and 8% wallpaper through ii's global
#              opacity rule is not frost, per the MANIFEST caveat), while a
#              translucent window over a sharp wallpaper is a window, not glass.
#              Measured as high-frequency energy: the wallpaper under the window
#              has detail, the same wallpaper seen THROUGH the window must have
#              much less of it, and must not be flat -- flat means opaque paint.
#   P2 MOTION  filmed, not asserted. The window's own open and close are timed
#              off the film and must decelerate in, accelerate out, land in the
#              200-400ms band, and the exit must be 20-30% faster.
#
# The film is wf-recorder because one-shot grim returns stale frames [brief], and
# the app is opened over a DETAILED region of the wallpaper on purpose: frost
# measured over a flat sky is a measurement of the sky.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=/mnt/host/zrig/phase11/x64; mkdir -p "$OUT"
FAIL=0
bad() { echo "FAIL $*"; FAIL=1; }
APP=$HOME/.local/bin/hyprdrive-settings

[ -x "$APP" ] || { echo "FAIL $APP is not installed -- run scripts/install-fragments.sh"; exit 1; }
command -v wf-recorder >/dev/null || { echo "FAIL no wf-recorder"; exit 1; }

gate_slate x64_app_obeys_laws >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }
[ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_pause 30min
headless_on || exit 1
x64_stop() { pkill -f "hyprdrive[-]settings" >/dev/null 2>&1; pkill -x wf-recorder >/dev/null 2>&1; }
trap 'x64_stop; headless_off; hyprwall_resume' EXIT

# The app must sit over wallpaper, not over another window.
killothers NONE >/dev/null 2>&1
sleep 1

# ------------------------------------------------------------------ P2 MOTION --
# Filmed first: the frost measurement needs the window settled, and settling is
# what the film is timing.
echo "--- P2 MOTION (filmed)"
wf-recorder -o "$RIG_MON" -f "$OUT/open.mp4" -r 60 >"$OUT/wfr-open.log" 2>&1 &
WFR=$!
sleep 2
setsid "$APP" >"$OUT/app.log" 2>&1 &
sleep 6
kill -INT $WFR 2>/dev/null; wait $WFR 2>/dev/null || true
sleep 1

WIN=$(hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c['title'] == 'Hyprdrive Settings':
        print('%d %d %d %d' % (c['at'][0], c['at'][1], c['size'][0], c['size'][1])); break")
[ -n "$WIN" ] || { echo "FAIL the app never mapped"; exit 1; }
read -r WX WY WW WH <<< "$WIN"
echo "    window at ${WX},${WY} ${WW}x${WH}"

wf-recorder -o "$RIG_MON" -f "$OUT/close.mp4" -r 60 >"$OUT/wfr-close.log" 2>&1 &
WFR=$!
sleep 2
# Close it the way the close button does: the app runs its exit animation and
# quits at the end of it.
hyprctl dispatch closewindow title:"Hyprdrive Settings" >/dev/null 2>&1 \
    || hyprctl eval 'for _, w in ipairs(hl.get_windows()) do if w.title == [[Hyprdrive Settings]] then hl.dispatch(hl.dsp.focus({window = w})) hl.dispatch(hl.dsp.window.close()) end end return 1' >/dev/null 2>&1
sleep 4
kill -INT $WFR 2>/dev/null; wait $WFR 2>/dev/null || true
sleep 1

python3 scripts/x64_motion.py "$OUT/open.mp4" "$OUT/close.mp4" "$WX,$WY,$WW,$WH" "$OUT" || FAIL=1

# ------------------------------------------------------------------- P1 FROST --
echo
echo "--- P1 FROST"
# Bare desktop first: the wallpaper as it is, with nothing over it.
x64_stop; sleep 2
grim -o "$RIG_MON" "$OUT/desktop.png"
setsid "$APP" >>"$OUT/app.log" 2>&1 &
sleep 6
grim -o "$RIG_MON" "$OUT/withapp.png"
WIN=$(hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c['title'] == 'Hyprdrive Settings':
        print('%d %d %d %d' % (c['at'][0], c['at'][1], c['size'][0], c['size'][1])); break")
read -r WX WY WW WH <<< "$WIN"

python3 - "$OUT/desktop.png" "$OUT/withapp.png" "$WX" "$WY" "$WW" "$WH" <<'PY' || FAIL=1
import sys
import numpy as np
from PIL import Image

desk = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(float)
app = np.asarray(Image.open(sys.argv[2]).convert("RGB")).astype(float)
x, y, w, h = (int(v) for v in sys.argv[3:7])
# Well inside the window: away from its border, its nav rail and its text. The
# right-hand content area is the biggest run of surface the app has.
bx, by, bw, bh = x + int(w * 0.55), y + int(h * 0.70), int(w * 0.35), int(h * 0.22)


def energy(im):
    """High-frequency energy: mean absolute neighbour difference, in grey. Blur
    is exactly the operation that destroys this and leaves the mean alone."""
    g = im.mean(axis=2)[by:by + bh, bx:bx + bw]
    return float(np.abs(np.diff(g, axis=0)).mean() + np.abs(np.diff(g, axis=1)).mean()) / 2, float(g.mean())


e_desk, m_desk = energy(desk)
e_app, m_app = energy(app)
print("    wallpaper under the window: detail %.3f, mean %.1f" % (e_desk, m_desk))
print("    the same patch through it:  detail %.3f, mean %.1f" % (e_app, m_app))

ok = True
if e_desk < 1.0:
    print("    FAIL the wallpaper patch has no detail (%.3f) -- this measures nothing" % e_desk)
    ok = False
if e_app >= e_desk * 0.6:
    print("    FAIL detail through the window is %.0f%% of the raw wallpaper -- not blurred"
          % (100 * e_app / max(e_desk, 1e-6)))
    ok = False
if e_app <= 0.02:
    print("    FAIL the patch is flat (%.3f) -- the window is painting over the backdrop, not frosting it" % e_app)
    ok = False
if abs(m_app - m_desk) < 1.0 and e_app > e_desk * 0.6:
    print("    FAIL the window seems not to be there at all")
    ok = False
if ok:
    print("    frosted: detail cut to %.0f%% of the wallpaper's, and still non-zero"
          % (100 * e_app / e_desk))
sys.exit(0 if ok else 1)
PY

alive_or_die "the whole run"
echo
[ $FAIL = 0 ] && echo "X64 PASS -- the app is frosted and its motion obeys the rules it edits" || echo "X64 FAIL"
exit $FAIL
