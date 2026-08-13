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

# Evidence goes where the RUN says, not where the phase that wrote the gate
# went: a gate that hardcodes zrig/phase11 files its frames under a finished
# phase's directory forever, and a later round reading "the x64 films" gets the
# ones from 2026-08-12 whatever it just ran.
OUT=${X64_OUT:-${RIG_EVIDENCE:-/mnt/host/zrig}/x64}; mkdir -p "$OUT"
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

desk = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(float).mean(axis=2)
app = np.asarray(Image.open(sys.argv[2]).convert("RGB")).astype(float).mean(axis=2)
x, y, w, h = (int(v) for v in sys.argv[3:7])
# Well inside the window: away from its border, its nav rail and its text. The
# right-hand content area is the biggest run of surface the app has.
bx, by, bw, bh = x + int(w * 0.55), y + int(h * 0.70), int(w * 0.35), int(h * 0.22)
pd, pa = desk[by:by + bh, bx:bx + bw], app[by:by + bh, bx:bx + bw]

# WHAT IS MEASURED, AND WHY IT IS NOT THE RAW DETAIL ANY MORE.
#
# This used to compare the high-frequency energy of the patch against the
# wallpaper's own and require it to fall below 60%. That number is not a
# measurement of the blur, it is a measurement of HOW MUCH APP TEXT the patch
# happens to contain relative to how detailed the wallpaper happens to be, and
# it decided this gate's verdict twice on 2026-08-12 with the blur working
# perfectly both times:
#   * on wp17 (detail 9.3) a correctly frosted window reads 0.27 and passes;
#   * on wp06 (detail 2.7, the picture the convergence pair actually ran on
#     because nothing pinned the wallpaper) the SAME correctly frosted window,
#     with the same app text in the patch, reads 0.95 and fails;
#   * and a synthetic 45%-alpha UNBLURRED overlay -- the exact defect this is
#     supposed to catch -- reads 0.45 on both and PASSES.
# The old check was therefore backwards as often as it was right.
#
# Blur is a low-pass filter, so the honest question is which of the wallpaper's
# own frequencies survive behind the window:
#   HIGH  they must NOT. If the wallpaper's fine structure is still correlated
#         with what is on screen, the backdrop is being shown, not frosted.
#   LOW   they MUST. That is what makes it glass rather than paint; an opaque
#         window carries none of the backdrop's shape at any frequency.
# Both are CORRELATIONS, so they are immune to the wallpaper's contrast, to the
# window's alpha, and to the app's own content (which is uncorrelated with the
# wallpaper and cancels).
#
# CALIBRATION, 8 runs over two wallpapers (zrig/danglingB2/wear/):
#   real frosted window   hp 0.002-0.006   lp 0.393-0.521
#   synthetic unblurred   hp 1.000         lp 1.000
#   synthetic opaque      hp 0.001-0.004   lp 0.003-0.054
# Thresholds sit outside both measured bands with margin: hp < 0.25 is 40x above
# every real reading and 4x below the unblurred one; lp > 0.20 is half the worst
# real reading and 4x the worst opaque one.
HP_MAX, LP_MIN = 0.25, 0.20


def hp(g):
    """High-frequency part: the pixel minus its four neighbours' mean."""
    return g - (np.roll(g, 1, 0) + np.roll(g, -1, 0) + np.roll(g, 1, 1) + np.roll(g, -1, 1)) / 4.0


def lp(g, k=16):
    """Low-frequency part: 16x16 block means, which is coarser than any blur
    radius the compositor is configured with and so survives one."""
    hh, ww = g.shape[0] - g.shape[0] % k, g.shape[1] - g.shape[1] % k
    return g[:hh, :ww].reshape(hh // k, k, ww // k, k).mean(axis=(1, 3))


def ncorr(a, b):
    a = a.ravel() - a.mean()
    b = b.ravel() - b.mean()
    d = np.sqrt((a * a).sum() * (b * b).sum())
    return float((a * b).sum() / d) if d else 0.0


def energy(g):
    return float(np.abs(np.diff(g, axis=0)).mean() + np.abs(np.diff(g, axis=1)).mean()) / 2


e_desk, e_app = energy(pd), energy(pa)
hpc = ncorr(hp(pd)[2:-2, 2:-2], hp(pa)[2:-2, 2:-2])
lpc = ncorr(lp(pd), lp(pa))
print("    wallpaper under the window: detail %.3f, mean %.1f" % (e_desk, pd.mean()))
print("    the same patch through it:  detail %.3f, mean %.1f" % (e_app, pa.mean()))
print("    wallpaper structure through the window: high %+.3f (want < %.2f), low %+.3f (want > %.2f)"
      % (hpc, HP_MAX, lpc, LP_MIN))

ok = True
if e_desk < 0.5:
    print("    FAIL the wallpaper patch has no detail (%.3f) -- this measures nothing" % e_desk)
    ok = False
if hpc >= HP_MAX:
    print("    FAIL the wallpaper's own fine detail is still there through the window "
          "(high-frequency correlation %+.3f) -- translucent, not frosted" % hpc)
    ok = False
if lpc <= LP_MIN:
    print("    FAIL the backdrop's shape is not there at all (low-frequency correlation %+.3f) "
          "-- the window is painting over it, not frosting it" % lpc)
    ok = False
if e_app <= 0.02:
    print("    FAIL the patch is flat (%.3f) -- nothing is being drawn there" % e_app)
    ok = False
if ok:
    print("    frosted: the wallpaper's fine detail is gone (%+.3f) and its shape is still "
          "there (%+.3f); detail cut to %.0f%%" % (hpc, lpc, 100 * e_app / e_desk))
sys.exit(0 if ok else 1)
PY

alive_or_die "the whole run"
echo
[ $FAIL = 0 ] && echo "X64 PASS -- the app is frosted and its motion obeys the rules it edits" || echo "X64 FAIL"
exit $FAIL
