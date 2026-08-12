#!/usr/bin/env bash
# z10_theme_adopt -- a wallpaper swap repaints the dock and the overview, by
# itself, and a pinned surface does not move.
#
# This is Phase 10's whole claim in one run. The gate never calls theme-sync: it
# swaps the wallpaper through the rice's own rotation script and then WAITS to
# be able to prove that systemd's path unit noticed matugen's palette and ran
# the sync on its own. "No manual step" is not a thing you can assert by not
# doing one -- it is asserted here by requiring somebody ELSE to have acted
# (the service's InvocationID changes, and theme-sync's own log gains a line),
# and "no restart" by the compositor instance signature being the same one at
# the end that it was at the start.
#
#   P1 INHERIT   wp18 -> wp15. The dock pill and the overview strip ring must
#                both repaint, to the new palette, while nothing restarts.
#   P2 PIN       the dock's two accent keys are pinned in a fragment that sorts
#                after the derived one, wp15 -> wp06. The overview must still
#                repaint; the dock must not move at all. One swap, both sides
#                of the masking rule, so neither can pass by the session simply
#                being stuck.
#
# Three rig mechanisms are load-bearing and none of them is decoration:
#
#   the OPAQUE fixture across the dock band. The pill is translucent and the
#   wallpaper behind it is the thing being changed, so without a constant
#   backdrop "the pill's pixels moved" would be true no matter what the plugin
#   did. The fixture is kitty at background_opacity=1.0 (standing rule: never
#   foot) and the grader checks the backdrop really did hold still.
#
#   98-z10-rig.lua. theme-sync applies with `hyprctl reload`, and a reload
#   re-applies the monitor config -- measured 2026-08-12, it brings Virtual-1
#   back up and resets the headless output to 1920x1080 at x=2560, which would
#   move every measured pixel between the two frames of the A/B. It also puts
#   dock:autohide back to its configured value and hides the dock. So the rig's
#   own settings go in a FRAGMENT, where a reload re-applies them instead of
#   undoing them. Phase 9's layer, used as intended.
#
#   the wallpaper pair. wp18 (#a1d749) and wp15 (#7dd4d8) are chosen because
#   their accents match 0.000% of all 22 wallpapers at the grader's tolerance;
#   z3 is red on some wallpapers precisely because it takes a colour blob off a
#   photograph. The grader re-measures that on every frame anyway.
#
# WHAT THIS IS RED ON, AND WHY IT IS NOT THE OBVIOUS THING. Hyprland 0.56
# reloads itself when a config file it has already sourced changes, so matugen
# rewriting hyprland/colors.lua re-applied col_highlight long before this phase
# existed. Both fail-on-old runs are on record and they fail differently:
#
#   parent 6b50930, nothing installed (z10-on-parent.log): the OVERVIEW arms
#   pass -- that is the pre-existing auto-reload, honestly reported -- and the
#   dock arms are stone dead at 0.00 px because matugen writes no dock key, plus
#   every pipeline assertion fails. Red.
#
#   the derived fragment present and the sync switched off (z10-stale-pin.log):
#   BOTH accents freeze. A fragment that sorts after colors.lua wins every one
#   of those automatic reloads, so an un-regenerated derived fragment does not
#   merely fail to help, it stops the accent following the wallpaper at all.
#   That is the trap Phase 9 named, and this gate is what stands over it.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=/mnt/host/zrig/phase10/z10; mkdir -p $OUT
RIGFRAG=$HOME/.config/hypr/hyprdrive/98-z10-rig.lua
PINFRAG=$HOME/.config/hypr/hyprdrive/15-z10-pin.lua
SYNCLOG=${XDG_STATE_HOME:-$HOME/.local/state}/hyprdrive/theme-sync.log
IICFG=$HOME/.config/illogical-impulse/config.json
FIXCOL='#101820'
FAIL=0
bad() { echo "FAIL $*"; FAIL=1; }

WALL0=$(jq -r '.background.wallpaperPath' "$IICFG")

# headless_on installs its own EXIT trap, so it goes FIRST and everything else
# chains behind it -- the rig header's rule, and the one an earlier probe in
# this phase broke and left the session with a disabled Virtual-1.
gate_slate z10_theme_adopt >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }
# Standalone only. Under suite.sh the rotation is already held for the whole run
# and calling hyprwall_pause again would REPLACE that 180min dead-man resume
# with a 30min one -- re-arming the rotation in the middle of a longer suite,
# under gates that are diffing frames. This is the one gate that moves the
# wallpaper itself, so a timer firing underneath it is not survivable either.
[ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_pause 60min
headless_on || exit 1
z10_restore() {
    rm -f "$RIGFRAG" "$PINFRAG"
    # Put the wallpaper AND the palette back the way they were found: the suite
    # holds the wallpaper still for every other gate, and this is the one gate
    # that moves it on purpose.
    THEME=1 WALL="$WALL0" bash scripts/hyprwall-rotate.sh >/dev/null 2>&1
    sleep 3
    hyprctl reload >/dev/null 2>&1
    sleep 2
}
trap 'z10_restore; headless_off; hyprwall_resume' EXIT

# ------------------------------------------------------------------ preflight --
command -v matugen >/dev/null || { echo "FAIL no matugen in this guest"; exit 1; }
[ -x scripts/theme-sync.py ] && echo "preflight: theme-sync.py present" \
    || bad "preflight: no scripts/theme-sync.py -- this build has no theme adoption pipeline"
UNIT=$(systemctl --user is-active hyprdrive-theme-sync.path 2>/dev/null || true)
echo "preflight: hyprdrive-theme-sync.path is ${UNIT:-absent}"
[ "$UNIT" = active ] || bad "preflight: the palette watch is not running -- nothing will fire on a swap"
echo "preflight: fragments -> $(ls ~/.config/hypr/hyprdrive/ | tr '\n' ' ')"

# The rig's own session settings, in a fragment so the reload re-applies them.
cat > "$RIGFRAG" <<LUA
-- z10_theme_adopt rig. Removed by the gate's EXIT trap.
-- These live in a fragment and not in a live hl.config write because
-- theme-sync applies with \`hyprctl reload\`, and a reload discards live writes
-- and re-applies the monitor config. 98 so it cannot mask a derived key.
hl.monitor({output = [[$RIG_MON]], mode = [[$RIG_HEADLESS_MODE]], position = [[0x0]], scale = 1})
hl.monitor({output = [[Virtual-1]], disabled = true})
-- The backdrop fixture has to be OPAQUE and kitty's own background_opacity=1.0
-- is not enough: custom/rules.lua:40 puts a 0.92/0.86 opacity rule on class
-- ".*", so every "opaque" fixture in this guest is 8% wallpaper. Measured
-- 2026-08-12 -- the first cut of this gate reported the dock pill repainting
-- when what had moved was the photograph behind the fixture. The fragments load
-- after custom/*, so this rule is the later one and wins.
hl.window_rule({match = {class = "^(Z10BACK)$"}, opacity = "1.0 1.0"})
hl.window_rule({match = {class = "^(Z10BACK)$"}, no_blur = true})
if hyprdrive_loaded() then
    hl.config({ plugin = { hyprdrive = { dock = { autohide = false } } } })
end
LUA
hyprctl reload >/dev/null 2>&1; sleep 2.5
MONS=$(hyprctl monitors -j | python3 -c "
import json,sys
m=json.load(sys.stdin); print('%s %d %d' % (m[0]['name'], m[0]['width'], m[0]['height']) if len(m)==1 else 'none')")
echo "preflight: after a reload the outputs are '$MONS'"
[ "$MONS" = "$RIG_MON $RIG_W $RIG_H" ] || { echo "FAIL the rig fragment did not hold the output across a reload"; exit 1; }
opt_want $RIG_KEY:dock:autohide false || bad "preflight: the dock is still autohiding"

# The opaque backdrop under the dock, and a ticking window elsewhere so the
# capture pipeline can be proven live [rig.sh pipeline_live_or_die].
fixture_kitty Z10BACK 0 1380 2560 220 "$FIXCOL" || { echo "FAIL no backdrop fixture"; exit 1; }
fixture_kitty Z10TICK 300 200 900 400 "#301030" "i=0; while :; do echo \$i; i=\$((i+1)); sleep 0.08; done" \
    || { echo "FAIL no ticking fixture"; exit 1; }
place() {   # re-assert both fixtures: a reload can retile under us
    hyprctl eval "$(cat <<'LUA'
for _, w in ipairs(hl.get_windows()) do
    if w.class == "Z10BACK" then
        hl.dispatch(hl.dsp.focus({window = w}))
        hl.dispatch(hl.dsp.window.resize({x = 2560, y = 220, relative = false}))
        hl.dispatch(hl.dsp.window.move({x = 0, y = 1380, relative = false}))
    elseif w.class == "Z10TICK" then
        hl.dispatch(hl.dsp.focus({window = w}))
        hl.dispatch(hl.dsp.window.resize({x = 900, y = 400, relative = false}))
        hl.dispatch(hl.dsp.window.move({x = 300, y = 200, relative = false}))
    end
end
return 1
LUA
)" >/dev/null 2>&1
    sleep 1.2
}
place
pipeline_live_or_die $OUT live

# The opacity rule is the whole basis of the dock measurement, so prove it took
# rather than assuming it. A translucent fixture is a backdrop that moves with
# the wallpaper, and every dock number after this would be measuring that.
grim -o "$RIG_MON" $OUT/fixture-probe.png
python3 - "$OUT/fixture-probe.png" "$FIXCOL" <<'PY' || bad "the backdrop fixture is not opaque -- the dock A/B cannot be trusted"
import sys
import numpy as np
from PIL import Image
im = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
want = np.array([int(sys.argv[2].lstrip("#")[i:i+2], 16) for i in (0, 2, 4)])
# A patch well inside the fixture and well left of the pill.
patch = im[1450:1550, 300:700].reshape(-1, 3)
off = float(np.abs(patch - want).mean())
print("preflight: backdrop fixture is off its own colour by %.2f (want < 3)" % off)
sys.exit(0 if off < 3 else 1)
PY

# ------------------------------------------------------------------- helpers --
palette() { jq -r "$1" ~/.local/state/quickshell/user/generated/colors.json; }

# Swap the wallpaper the way the rice does, then prove SOMETHING ELSE reacted.
swap() { # swap WPNAME LABEL
    local wp=$1 label=$2 n0 n1 inv0 inv1 i
    n0=$(wc -l < "$SYNCLOG" 2>/dev/null || echo 0)
    inv0=$(systemctl --user show hyprdrive-theme-sync.service -p InvocationID --value 2>/dev/null)
    echo "--- swap to $wp ($label)"
    THEME=1 WALL=/mnt/host/wallpapers/$wp.jpg bash scripts/hyprwall-rotate.sh
    for i in $(seq 1 40); do
        n1=$(wc -l < "$SYNCLOG" 2>/dev/null || echo 0)
        [ "$n1" -gt "$n0" ] && break
        sleep 0.5
    done
    inv1=$(systemctl --user show hyprdrive-theme-sync.service -p InvocationID --value 2>/dev/null)
    if [ "${n1:-0}" -gt "$n0" ]; then
        echo "    theme-sync ran on its own: $(tail -1 "$SYNCLOG")"
    else
        bad "$label: theme-sync never ran -- the path unit did not fire on the palette write"
    fi
    [ -n "$inv1" ] && [ "$inv1" != "$inv0" ] \
        || bad "$label: hyprdrive-theme-sync.service was not started by systemd (invocation $inv0 -> ${inv1:-none})"
    # quickshell repaints the wallpaper about 4s after the config write; the
    # reload has long since happened by then.
    sleep 7
    place
    alive_or_die "$label: after the swap"
}

shoot() { # shoot TAG -- desktop pair, then overview pair
    local t=$1
    grim -o "$RIG_MON" $OUT/dock-$t-0.png; sleep 0.5; grim -o "$RIG_MON" $OUT/dock-$t-1.png
    ov on; sleep 2.5
    grim -o "$RIG_MON" $OUT/ov-$t-0.png; sleep 0.5; grim -o "$RIG_MON" $OUT/ov-$t-1.png
    ov_off_settled
    echo "    $t: accent=$(palette .primary) pill=$(palette .primary_container) " \
         "col_highlight=$(hyprctl getoption $RIG_KEY:col_highlight | head -1 | cut -d: -f2-)" \
         "bg=$(hyprctl getoption $RIG_KEY:dock:background_color | head -1 | awk '{print $2}')"
}

# ------------------------------------------------------------ P1: INHERIT --
[ -e "$PINFRAG" ] && rm -f "$PINFRAG"
swap wp18 "P1 baseline"
A_ACCENT=$(palette .primary); A_PILL=$(palette .primary_container)
shoot A
swap wp15 "P1 measured"
B_ACCENT=$(palette .primary); B_PILL=$(palette .primary_container)
shoot B

# ---------------------------------------------------------------- P2: PIN --
# A pin is not a new file format: it is the key, written by a human, in a
# fragment that loads after the derived one. This is what the docs tell a user
# to type, typed.
cat > "$PINFRAG" <<'LUA'
-- z10_theme_adopt: the DOCK is pinned, the overview is not. Removed by the
-- gate's EXIT trap. 15 > 05, so this wins over the derived fragment by load
-- order alone -- which is the entire masking mechanism.
if hyprdrive_loaded() then
    hl.config({ plugin = { hyprdrive = { dock = {
        background_color = 0xFFC0BFBC,
        indicator_color  = 0xFFFAFAFB,
    } } } })
end
LUA
hyprctl reload >/dev/null 2>&1; sleep 2.5
place
echo "--- pin written; theme-sync now reports masked keys:"
python3 scripts/theme-sync.py --no-apply | sed 's/^/    /'
MASKED=$(tail -1 "$SYNCLOG")
case "$MASKED" in
    *masked=*background_color*) ;;
    *) bad "P2: theme-sync did not notice the dock pin (log says: $MASKED)" ;;
esac
case "$MASKED" in
    *masked=*indicator_color*) ;;
    *) bad "P2: theme-sync did not notice the dock pin (log says: $MASKED)" ;;
esac
P_ACCENT=$(palette .primary)
shoot P
swap wp06 "P2 measured"
C_ACCENT=$(palette .primary)
shoot C

# ----------------------------------------------------------------- grading --
cat > $OUT/manifest.json <<JSON
{
  "out": "$OUT",
  "fixture": "$FIXCOL",
  "alpha": 0.22,
  "dock_band": [1400, 1600],
  "strip_band": [150, 500],
  "edge_px": 180,
  "steps": {
    "A": {"accent": "$A_ACCENT", "pill": "$A_PILL"},
    "B": {"accent": "$B_ACCENT", "pill": "$B_PILL"},
    "P": {"accent": "$P_ACCENT", "pill": "#C0BFBC"},
    "C": {"accent": "$C_ACCENT", "pill": "#C0BFBC"}
  },
  "checks": [
    {"name": "P1 INHERIT dock",     "kind": "dock", "from": "A", "to": "B", "expect": "change"},
    {"name": "P1 INHERIT overview", "kind": "ring", "from": "A", "to": "B", "expect": "change"},
    {"name": "P2 PINNED dock",      "kind": "dock", "from": "P", "to": "C", "expect": "same"},
    {"name": "P2 INHERIT overview", "kind": "ring", "from": "P", "to": "C", "expect": "change"}
  ]
}
JSON
echo
python3 scripts/z10_gate.py $OUT/manifest.json || FAIL=1

alive_or_die "the whole run"
echo
[ $FAIL = 0 ] && echo "Z10 PASS -- the wallpaper swapped, nothing restarted, nobody typed anything" || echo "Z10 FAIL"
exit $FAIL
