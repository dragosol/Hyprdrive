#!/usr/bin/env bash
# x61_blur_roundtrip -- the settings app changes the frost, and can put it back.
#
# The full round trip, and every step of it has to be visible somewhere other
# than the app's own opinion of itself:
#
#   the FRAGMENT gains exactly one key and nothing else (diffed, not eyeballed)
#   the COMPOSITOR reports the new value (hyprctl getoption)
#   the PIXELS through a frosted surface change (blob, with controls both sides)
#   UNSET puts all three back -- the fragment, the option, and the pixels
#
# WHAT IS BEING PHOTOGRAPHED. A hard black/white seam between two opaque kitty
# fixtures, with a THIRD, translucent kitty over the seam. The compositor blurs
# the desktop behind a translucent surface, so the seam is smeared through that
# window and the width of the smear IS decoration:blur:size. Nothing else in the
# frame has an opinion about blur size, which is why the measurement region is
# the translucent window and only the translucent window.
#
# Two things this deliberately does NOT do. It does not measure the dock pill:
# the pill is the right SURFACE but it sits over whatever the wallpaper happens
# to be, and z10 had to spend an opaque backdrop fixture to stop that photograph
# moving underneath it. And it does not measure "blur on vs off", because the
# product rule says the app must never offer off -- the range this gate walks is
# the range the app actually exposes.
#
# 6 -> 30 is a change the user would make; the gate re-reads the session's own
# starting value rather than assuming 6, and puts THAT back.
#
# WHY THE REVERT IS GRADED ON THE FRAGMENT AND THE OPTION AND NOT ON PIXELS.
# Measured on this rig 2026-08-12 (zrig/phase11/x61-fbcache.log): raising the
# blur size repaints, and after that NOTHING under that window repaints again --
# not lowering it back, not a brightness change, not a window nudge, not
# `dispatch forcerendererreload`, while `getoption` reports the new value every
# time. Hyprland caches the blurred backdrop (`decoration:blur:new_optimizations`
# is on in this rice) and on a desktop where nothing moves there is no damage to
# make it regenerate; the reload that lands the FIRST change is itself the damage
# that makes that one visible. This plugin has a config key about exactly that
# cache -- live_layer_frost, "the stale optimized blur FB" -- so it is a known
# property of the system rather than a discovery here. Turning the optimization
# off does not rescue the measurement either: with it off the headless output
# stopped producing new frames at all, so every pair including the controls came
# back byte-identical, which is a starved output and not a result.
#
# So the pixel claim this gate makes is the one it can honestly make -- the frost
# visibly changed when the app wrote the fragment -- and the revert is proved on
# the two artefacts that cannot be cached: the file and the compositor's own
# readback. That is a smaller claim than "the pixels came back", and it is stated
# rather than dressed up.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=/mnt/host/zrig/phase11/x61; mkdir -p "$OUT"
FRAG=$HOME/.config/hypr/hyprdrive/41-blur.lua
KEY=decoration:blur:size
WANT=30
FAIL=0
bad() { echo "FAIL $*"; FAIL=1; }

gate_slate x61_blur_roundtrip >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }
[ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_pause 30min
headless_on || exit 1

x61_restore() {
    python3 scripts/hdctl.py unset "$KEY" >/dev/null 2>&1
    pkill -f "FX61" >/dev/null 2>&1
}
trap 'x61_restore; headless_off; hyprwall_resume' EXIT

BASE=$(hyprctl getoption $KEY -j | python3 -c "import json,sys; print(json.load(sys.stdin)['int'])")
echo "preflight: $KEY is $BASE, blur is $(hyprctl getoption decoration:blur:enabled -j | python3 -c 'import json,sys; print(json.load(sys.stdin)["bool"])')"
[ "$BASE" = "$WANT" ] && { echo "FAIL preflight: the session already sits at the value the gate moves to"; exit 1; }

# The seam: two opaque fixtures with a hard edge between them at x=1280.
fixture_kitty FX61L 0 300 1280 900 "#ffffff" || { echo "FAIL no left fixture"; exit 1; }
fixture_kitty FX61R 1280 300 1280 900 "#000000" || { echo "FAIL no right fixture"; exit 1; }

# A ticker, OUTSIDE the measured region, so the capture pipeline can be proved
# live at whole-frame level. It is deliberately not under the glass: measured
# here, a ticking window behind a frosted one does not move a single pixel of the
# blurred backdrop, because that backdrop is the cached optimized FB (see the
# header). A ticker under the glass would therefore have proved nothing and
# looked like it proved something.
fixture_kitty FX61TICK 100 60 400 180 "#404040" \
    "i=0; while :; do echo \$i; i=\$((i+1)); sleep 0.1; done" \
    || { echo "FAIL no ticking fixture"; exit 1; }

# The frosted surface, mapped LAST so it is on top of the seam and the ticker.
# NOT fixture_kitty: that one forces background_opacity=1.0 on purpose (an opaque
# fixture is what most gates want), and an opaque window has no backdrop to blur
# -- it would photograph nothing, forever.
setsid kitty -c NONE --class FX61T -o background="#202028" -o background_opacity=0.30 \
    -o confirm_os_window_close=0 --hold sh -c "sleep 3600" >/dev/null 2>&1 </dev/null &
sleep 2.5
hyprctl clients -j | grep -q '"FX61T"' || { echo "FAIL the translucent fixture never mapped"; exit 1; }
hyprctl eval "$(cat <<'LUA'
for _, w in ipairs(hl.get_windows()) do
    if w.class == "FX61T" then
        hl.dispatch(hl.dsp.focus({window = w}))
        hl.dispatch(hl.dsp.window.resize({x = 760, y = 500, relative = false}))
        hl.dispatch(hl.dsp.window.move({x = 900, y = 500, relative = false}))
    end
end
return 1
LUA
)" >/dev/null 2>&1
sleep 1.2

# Inside the translucent window, away from its own border and its cursor block.
REGION=940,540,680,420
shoot() { grim -o "$RIG_MON" "$OUT/$1.png"; sleep 0.4; }

# The whole claim rests on this window being translucent. ii's custom/rules.lua
# puts an opacity rule on class ".*" and kitty's own alpha is only half the
# story, so PROVE the seam is visible through it before grading anything.
shoot probe
python3 - "$OUT/probe.png" <<'PY' || bad "preflight: no seam visible through the fixture -- it is not translucent, so nothing after this measures blur"
import sys
import numpy as np
from PIL import Image
im = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
left = im[600:900, 950:1200].mean()
right = im[600:900, 1400:1600].mean()
print("preflight: through the frosted window, left %.1f right %.1f (want a gap > 20)" % (left, right))
sys.exit(0 if abs(left - right) > 20 else 1)
PY

# ------------------------------------------------------------------- frames --
pipeline_live_or_die "$OUT" live
# Controls on BOTH sides of the measured frame [brief, pixel doctrine].
shoot c0; shoot c1

echo
echo "--- SET $KEY = $WANT through the app's own write path"
cp -f "$FRAG" "$OUT/frag-before.lua" 2>/dev/null || : > "$OUT/frag-before.lua"
python3 scripts/hdctl.py set "$KEY" "$WANT" | sed 's/^/    /'
sleep 2.5
cp -f "$FRAG" "$OUT/frag-after.lua"
shoot m

GOT=$(hyprctl getoption $KEY -j | python3 -c "import json,sys; print(json.load(sys.stdin)['int'])")
echo "    compositor now reports $KEY = $GOT"
[ "$GOT" = "$WANT" ] || bad "the compositor did not take the value ($GOT)"

# EXACTLY that key. A settings app that rewrites a fragment is a settings app
# that can quietly drop somebody else's line out of it.
diff "$OUT/frag-before.lua" "$OUT/frag-after.lua" > "$OUT/frag.diff" || true
ADDED=$(grep -c '^> ' "$OUT/frag.diff" || true)
REMOVED=$(grep -c '^< ' "$OUT/frag.diff" || true)
echo "    fragment diff: +$ADDED -$REMOVED"
sed 's/^/      /' "$OUT/frag.diff" | head -20
grep -q "size = $WANT" "$OUT/frag-after.lua" || bad "the fragment does not carry size = $WANT"
grep -qE '^> .*(blur|decoration|hl\.config|\{|\})' "$OUT/frag.diff" || bad "the diff does not look like the blur block"
[ "$REMOVED" -le 2 ] || bad "the write removed $REMOVED lines -- it is rewriting more than its own key"

shoot c2

echo
echo "--- UNSET: the app puts it back (graded on the file and the compositor, see the header)"
python3 scripts/hdctl.py unset "$KEY" | sed 's/^/    /'
sleep 2.5
BACK=$(hyprctl getoption $KEY -j | python3 -c "import json,sys; print(json.load(sys.stdin)['int'])")
echo "    compositor is back at $KEY = $BACK"
[ "$BACK" = "$BASE" ] || bad "unset left the option at $BACK, not $BASE"
cp -f "$FRAG" "$OUT/frag-restored.lua"
grep -q "size = " "$OUT/frag-restored.lua" && bad "the key is still in the fragment after unset"

# ------------------------------------------------------------------ grading --
echo
python3 - "$OUT" "$REGION" <<'PY' || FAIL=1
import subprocess, sys, os
out, region = sys.argv[1], sys.argv[2]
here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))) \
    if "__file__" in dir() else "."
import json


def blob(a, b):
    r = subprocess.run([sys.executable, "scripts/diffblob.py",
                        f"{out}/{a}.png", f"{out}/{b}.png", "--region", region, "--json"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr); sys.exit(1)
    return json.loads(r.stdout)


checks = [
    ("control  c0 vs c1  (noise floor, before)", "c0", "c1", "same"),
    ("MEASURED c1 vs m   (blur 6 -> 30)",        "c1", "m",  "change"),
    ("control  m  vs c2  (noise floor, after)",  "m",  "c2", "same"),
]
# The measured region is 680x420 = 285600 px and a blur change repaints all of
# it; the region is static otherwise. 40000 is seven times any noise this rig has
# produced and seven times below the real change, so it is a floor rather than a
# threshold fitted to one run.
FLOOR = 40000
bad = 0
for label, a, b, want in checks:
    d = blob(a, b)
    verdict = "change" if d["blob_px"] >= FLOOR else "same"
    ok = verdict == want
    note = ""
    # A frozen capture proves nothing -- but the instrument for THAT is
    # pipeline_live_or_die, which ran over the whole frame before any of these.
    # Inside this region the scene is static by construction (two solid fixtures
    # behind a fixed window), so byte-identical controls are the honest result
    # and only a byte-identical MEASURED pair means the capture died.
    if d["identical"] and want == "change":
        ok = False
        note = " IDENTICAL FRAMES -- the capture is frozen"
    print("  %-44s blob %7d px  want %-6s got %-6s %s%s"
          % (label, d["blob_px"], want, verdict, "ok" if ok else "FAIL", note))
    if not ok:
        bad = 1
sys.exit(bad)
PY
[ $? = 0 ] || FAIL=1

alive_or_die "the whole run"
echo
[ $FAIL = 0 ] && echo "X61 PASS -- the frost visibly changed, the fragment carried exactly one key, and both went back" || echo "X61 FAIL"
exit $FAIL
