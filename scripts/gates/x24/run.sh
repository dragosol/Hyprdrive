#!/usr/bin/env bash
# x24 gate -- dock-click flow, all four halves, GUEST-side end to end:
#   A  state half:   minimize keeps the window MAPPED on special:minimized,
#                    restore returns it (geometry unchanged, raised in PIXELS),
#                    P9 restore onto a reaped workspace  [x24_minimize.sh + x24_gate.py]
#   B  dock half:    icon click minimizes/restores the RIGHT class, gutter is a
#                    no-op  [x24_dock_fixture.sh + x24_dock_click.sh + x24_dock_gate.py]
#   C  overview:     a dock click with the overview open leaves it open
#                    (two-control pixel gate)  [x24_ov_click.sh + x24_ov_gate.py]
#   D  flight:       the minimize is ANIMATED into the pill, P1..P7
#                    [x24_click.sh + x26_points.py + x24_flight_gate.py]
# Half D ports the orchestration of the old host driver x24_flight_run.sh
# (ssh/g calls replaced with direct local commands; grading runs guest-side).
#
# Click expectations follow Dock.cpp's Y4 semantics (activateItem): a plain
# click toggles the WHOLE app (minimize all visible / restore all), SHIFT has
# converged with plain, CTRL cycles, the gutter swallows the press.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

OUT_STATE=/mnt/host/x24
OUT_DOCK=/mnt/host/x24d
mkdir -p "$OUT_STATE" "$OUT_DOCK"
fail=0
phase() { echo; echo "== x24: $*"; }

# The cell predictor models RUNNING CLASSES only: favourites, trash and the
# apps button are pinned items it cannot model (z_rig.sh measured a click on a
# favourite), and autohide keeps the pill away on the desktop. Config them off
# for the run, back to the Config.cpp defaults afterwards.
dock_test_cfg()    { cfg_dock "autohide=false, show_favorites=false, show_trash=false, show_mounts=false, show_apps_button=false"; }
dock_default_cfg() { cfg_dock "autohide=true, show_favorites=true, show_trash=true, show_mounts=false, show_apps_button=true"; }

# Sweep every window that is not an x24 fixture. Same rule as rig.sh
# killothers, but keeping BOTH dock-fixture classes (killothers keeps one);
# Nautilus gets D-Bus-activated back between a startup sweep and a click, so
# this runs immediately before every dock click [z_rig.sh:20-23].
sweep() {
    hyprctl clients -j | python3 -c "
import json,sys
keep=('X24DUO','X24SOLO','')
for c in json.load(sys.stdin):
    if c.get('class') not in keep and c.get('pid',0)>0: print(c['pid'])" \
        | xargs -r kill -9 2>/dev/null
    return 0
}

x24_cleanup() {
    ov off
    pkill -f -- '--class X24' 2>/dev/null   # X24BIG/X24TOP/X24DUO/X24SOLO
    pkill -f -- '--class x24' 2>/dev/null   # x24fix/x24other
    dock_default_cfg
    return 0
}

hyprwall_pause
headless_on || exit 1
trap 'x24_cleanup; headless_off; hyprwall_resume' EXIT   # chained per rig.sh header
dock_test_cfg; sleep 0.8

# ---- A: state half ----------------------------------------------------------
phase "state half (minimize/restore/P9)"
STATE_LOG=$OUT_STATE/minimize-run.log
bash scripts/x24_minimize.sh >"$STATE_LOG" 2>&1
rc=$?
cat "$STATE_LOG"
[ $rc -eq 0 ] || { echo "x24: minimize rig exited $rc"; fail=1; }
grep -q 'X24_RESULT OK'    "$STATE_LOG" || { echo "x24: state verdict not OK"; fail=1; }
grep -q 'X24_STRANDING OK' "$STATE_LOG" || { echo "x24: P9 stranding verdict not OK"; fail=1; }
alive_or_die "after the state half"

phase "raise gate (pixels at the overlap)"
python3 scripts/x24_gate.py "$OUT_STATE" || { echo "x24: raise gate red"; fail=1; }

# ---- B: dock half -----------------------------------------------------------
phase "dock half fixture"
sweep; sleep 1.2
bash scripts/x24_dock_fixture.sh || { echo "x24: dock fixture script failed"; fail=1; }
FIXSET=$(hyprctl clients -j | python3 -c "
import json,sys
cs=[c['class'] for c in json.load(sys.stdin)]
print(cs.count('X24DUO'), cs.count('X24SOLO'))")
if [ "$FIXSET" != "2 1" ]; then
    echo "x24: dock fixture wrong window set (X24DUO,X24SOLO counts = $FIXSET)"; fail=1
else
    dock_case() { # dock_case TARGET SHIFTMODE EXPECT CLASS LABEL
        local target=$1 shiftmode=$2 expect=$3 cls=$4 label=$5
        phase "dock click: $label"
        sweep; sleep 0.6
        bash scripts/x24_dock_click.sh "$target" "$shiftmode" || return 1
        alive_or_die "after dock click $target"
        python3 scripts/x24_dock_gate.py "$expect" "$cls"
    }
    dock_case X24DUO  noshift minimized-all X24DUO  "plain on DUO stashes the whole app" || fail=1
    dock_case X24DUO  noshift restored      X24DUO  "second plain on DUO restores all"   || fail=1
    dock_case X24SOLO shift   minimized-one X24SOLO "shift on SOLO stashes its window"   || fail=1
    dock_case X24SOLO noshift restored      X24SOLO "plain on SOLO restores it"          || fail=1
    dock_case gutter  noshift nochange      X24DUO  "gutter press is swallowed"          || fail=1
fi

# ---- C: overview stays open -------------------------------------------------
phase "overview stays open across a dock click"
sweep; sleep 0.6
bash scripts/x24_ov_click.sh X24SOLO || { echo "x24: overview click script failed"; fail=1; }
alive_or_die "after the overview click"
python3 scripts/x24_ov_gate.py || { echo "x24: overview-stays-open gate red"; fail=1; }

# ---- D: flight --------------------------------------------------------------
phase "flight (animated minimize into the pill)"
bash scripts/x24_click.sh setup || { echo "x24: flight setup failed"; fail=1; }
read -r ICX ICY <<< "$(python3 scripts/x26_points.py "$OUT_STATE/open.png" icon)"
if [ -z "${ICX:-}" ] || [ -z "${ICY:-}" ]; then
    echo "x24: could not measure the icon target off open.png"; fail=1
else
    echo "x24: icon target $ICX,$ICY"
    bash scripts/x24_click.sh "$ICX" "$ICY" || { echo "x24: flight click failed"; fail=1; }
    alive_or_die "after the flight"
    ( cd "$OUT_STATE" && exec python3 "$REPO/scripts/x24_flight_gate.py" ) \
        || { echo "x24: flight gate red"; fail=1; }
fi

echo
if [ "$fail" = 0 ]; then echo "X24_GATE PASS"; else echo "X24_GATE FAIL"; fi
exit "$fail"
