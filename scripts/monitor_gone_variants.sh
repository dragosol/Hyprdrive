#!/usr/bin/env bash
# P0 VARIANTS -- the states monitor_gone_repro.sh does not cover.
#
# The repro yanks an output from under an IDLE open overview. These are the four
# states where the monitor-removed teardown has something in its hands:
#
#   V1 mid-open   the overview is still ANIMATING when its output goes. Its
#                 animated variables are live, and destroying one from inside a
#                 callback is the crash the g_dyingOverviews park exists for.
#   V2 search     a query is typed and the results band is up. Proven live: the
#                 frames before and after the keystrokes must differ, or the
#                 variant is measuring an overview that never searched.
#   V3 minimize   a dock MINIMIZE flight is in the air. It must end minimized --
#                 the user asked for that -- and reachable.
#   V4 restore    a dock RESTORE flight is in the air. Worst case of the four:
#                 with the overview up the real window is setHidden(true) for the
#                 length of the flight, so a flight that never lands is a window
#                 the user cannot see, focus or get back.
#
# Same contract as the repro: run it over SSH, NEVER from a terminal inside the
# session. Exits 0 if every variant survived AND landed sanely, 1 if any did
# not, 2 if the rig could not set a scene up.
set -u
cd "$(dirname "$0")/.."
source scripts/lib/rig.sh
rig_env || exit 2

SIG0=$(rig_sig)
FAIL=0
OUT=${OUT:-/tmp/p0variants}
mkdir -p "$OUT"
echo "instance before: $SIG0"

mon()      { hyprctl eval "return hl.monitor({$1})" >/dev/null 2>&1; }
headless() { hyprctl monitors all -j 2>/dev/null | python3 -c "
import json,sys
try: mons = json.load(sys.stdin)
except Exception: mons = []          # dead socket: nothing to report, not a traceback
print(' '.join(m['name'] for m in mons if m['name'].startswith('HEADLESS')))"; }
client()   { # client ADDR FIELD
    hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c['address'] == '$1':
        v = c['$2']
        print(v['name'] if isinstance(v, dict) else v)
        break
else:
    print('GONE')"; }

# One headless output, and it is the ONLY one: Virtual-1 off means the overview,
# the keyboard and the pointer are all on the output about to be deleted.
scene_up() {
    ov off; sleep 1.2
    local m
    for m in $(headless); do hyprctl output remove "$m" >/dev/null 2>&1; sleep 0.4; done
    hyprctl output create headless >/dev/null 2>&1; sleep 1.5
    HL=$(hyprctl monitors -j | python3 -c "
import json,sys
hs=[m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')]
print(hs[0] if len(hs)==1 else '')")
    [ -n "$HL" ] || { echo "  ABORT: no headless output"; return 1; }
    mon "output = [[Virtual-1]], disabled = true"; sleep 1.5
    return 0
}

# The real output comes back BEFORE the one under the overview goes: removing the
# last enabled output leaves the session with nowhere to put its windows.
yank() {
    mon "output = [[Virtual-1]], disabled = false"; sleep 1.5
    hyprctl output remove "$HL" >/dev/null 2>&1; sleep 1.5
    echo "  removed $HL"
}

# Un-skippable: an abort between "Virtual-1 off" and the yank leaves the guest
# on a headless output with the real screen blank, which is a dead VM as far as
# every later rig is concerned.
restore_outputs() {
    # A variant that killed the compositor leaves this trap talking to a dead
    # socket, so re-discover first -- the session that needs its output back is
    # whichever one is live NOW.
    RIG_ENV_OK=0
    rig_env >/dev/null 2>&1 || return 0
    mon "output = [[Virtual-1]], disabled = false"; sleep 1.2
    local m
    for m in $(headless); do hyprctl output remove "$m" >/dev/null 2>&1; sleep 0.4; done
}
trap restore_outputs EXIT

alive() { # alive LABEL -- a changed signature means gdm restarted a corpse
    local now; now=$(rig_sig)
    if [ "$now" != "$SIG0" ]; then
        echo "  FAIL $1: compositor DIED ($SIG0 -> ${now:-gone})"
        echo "== $1 DIED" >> "$OUT/verdicts.txt"
        exit 1
    fi
    echo "  ok $1: instance unchanged"
    return 0
}

verdict() { # verdict LABEL PASS|FAIL [detail]
    echo "  ${2} ${1} ${3:-}"
    echo "$2 $1 ${3:-}" >> "$OUT/verdicts.txt"
    [ "$2" = PASS ] || FAIL=1
}

: > "$OUT/verdicts.txt"

# ------------------------------------------------------------ V1: mid-open --
echo "V1 mid-open"
scene_up || exit 2
anim_slow 8 || exit 2                 # the open is seconds long at 8x
ov on
sleep 0.4                             # comfortably inside it
yank
ov off; sleep 3
anim_restore
alive "V1 mid-open"
verdict "V1-midopen" PASS

# --------------------------------------------------------------- V2: search --
echo "V2 search active"
scene_up || exit 2
ov on; sleep 2.5
grim "$OUT/v2-pre.png" 2>/dev/null
ydotool type --key-delay 45 "kit"; sleep 2
grim "$OUT/v2-post.png" 2>/dev/null
if [ ! -s "$OUT/v2-pre.png" ] || [ ! -s "$OUT/v2-post.png" ]; then
    verdict "V2-search" FAIL "capture pipeline wrote nothing -- cannot prove a search was up"
elif cmp -s "$OUT/v2-pre.png" "$OUT/v2-post.png"; then
    verdict "V2-search" FAIL "frames identical across the keystrokes -- no search session to remove the monitor under"
else
    yank
    ov off; sleep 3
    alive "V2 search active"
    verdict "V2-search" PASS
fi

# ------------------------------------------------------ V3: minimize flight --
echo "V3 minimize flight in the air"
scene_up || exit 2
hyprctl eval "return hl.dispatch(hl.dsp.focus({window = [[class:kitty]]}))" >/dev/null 2>&1; sleep 0.6
ADDR=$(hyprctl activewindow -j | python3 -c "import json,sys; print(json.load(sys.stdin).get('address',''))")
[ -n "$ADDR" ] || { echo "  ABORT: nothing focused"; exit 2; }
cfg_dock "minimize_ms=6000"; sleep 0.4
ov on; sleep 2
dsp "hl.plugin.$RIG_NS.minimize([[window]])"
sleep 1.0                             # 6s flight: this is mid-air
# Positive control: the stash happens the instant the flight starts, so this is
# how the rig knows there IS a flight to remove the monitor under.
[ "$(client "$ADDR" workspace)" = "special:minimized" ] || { echo "  ABORT: no minimize flight in the air"; exit 2; }
yank
ov off; sleep 3
alive "V3 minimize flight"
WS=$(client "$ADDR" workspace)
if [ "$WS" = "special:minimized" ]; then
    verdict "V3-minimize-flight" PASS "window settled minimized"
else
    verdict "V3-minimize-flight" FAIL "window workspace '$WS', wanted special:minimized"
fi

# Put it back, no flight, so V4 starts from a known state.
cfg_dock "minimize_ms=0"; sleep 0.4
dsp "hl.plugin.$RIG_NS.minimize([[restore]])"; sleep 1.5

# ------------------------------------------------------- V4: restore flight --
echo "V4 restore flight in the air"
scene_up || exit 2
hyprctl eval "return hl.dispatch(hl.dsp.focus({window = [[class:kitty]]}))" >/dev/null 2>&1; sleep 0.6
ADDR=$(hyprctl activewindow -j | python3 -c "import json,sys; print(json.load(sys.stdin).get('address',''))")
[ -n "$ADDR" ] || { echo "  ABORT: nothing focused"; exit 2; }
cfg_dock "minimize_ms=0"; sleep 0.4
dsp "hl.plugin.$RIG_NS.minimize([[window]])"; sleep 1.5
[ "$(client "$ADDR" workspace)" = "special:minimized" ] || { echo "  ABORT: V4 setup did not minimize"; exit 2; }
cfg_dock "minimize_ms=6000"; sleep 0.4
ov on; sleep 2
dsp "hl.plugin.$RIG_NS.minimize([[restore]])"
sleep 1.0                             # mid-air, window HIDDEN
# Positive control: with the overview up a restore flight HIDES the real window
# for its whole length (restoreForFlight), so hidden=True is the flight itself.
[ "$(client "$ADDR" hidden)" = "True" ] || { echo "  ABORT: no restore flight in the air (window not hidden)"; exit 2; }
yank
ov off; sleep 3
alive "V4 restore flight"
WS=$(client "$ADDR" workspace)
HID=$(client "$ADDR" hidden)
if [ "$WS" != "special:minimized" ] && [ "$HID" = "False" ]; then
    verdict "V4-restore-flight" PASS "window came back visible on '$WS'"
else
    verdict "V4-restore-flight" FAIL "window workspace '$WS' hidden=$HID -- stranded"
fi

# ------------------------------------------------------------------ cleanup --
cfg_dock "minimize_ms=400"; sleep 0.3
anim_restore
for m in $(headless); do hyprctl output remove "$m" >/dev/null 2>&1; sleep 0.4; done
mon "output = [[Virtual-1]], disabled = false"; sleep 1.2

# The plugin must still WORK, not merely have avoided crashing: one full cycle
# on the output that is left.
ov on; sleep 2; ov off; sleep 2
alive "post-run cycle"

echo "instance after:  $(rig_sig)"
cat "$OUT/verdicts.txt"
[ "$FAIL" = 0 ] && { echo "ALL VARIANTS SURVIVED AND LANDED SANELY"; exit 0; }
echo "VARIANTS FAILED"
exit 1
