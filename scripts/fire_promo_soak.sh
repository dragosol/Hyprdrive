#!/usr/bin/env bash
# THE PHANTOM-TILE SOAK. Drives the render-list shadow (globals.hpp,
# HYPRDRIVE_RENDERLIST_SHADOW) through the state the user reported from: a
# window stashed FROM the ACTIVE desktop, a window on another desktop, a query
# typed and cleared, and the whole thing cycled.
#
# WHAT IT FOUND, 2026-08-17, on 9201a96 (logs in zrig/fire-phantom2/):
#   RENDER-GRIDDUP   4145   the stashed window takes TWO slots in the active
#                           grid -- the defect, fixed in GridLayout.cpp
#   RENDER-PROMONOQ    60   promoted tiles drawn with no query, ALL of them
#                           between "close the overview" and the next open, i.e.
#                           during the close animation: endInteraction empties
#                           the query while the last render list is on screen
#   RENDER-UNCLICK     48   a drawn tile's own centre hit-testing to another
#                           window, or to none at all
#   STALE/MISSING/DUP/CROSS 0   the render COPY agrees with the membership gate
#   DIVERGE                 0   and the membership CACHE agrees with the live one
#
# The last two lines are the point: the prime suspect -- a stale
# `images[i]->windows` -- is ACQUITTED. The divergence was inside the gate's own
# promotion arithmetic. After the fix: GRIDDUP 0, PROMONOQ 12 (all of them a
# genuinely off-desktop window releasing, which is F3-b working as designed),
# UNCLICK 13, and no hit=(none) at all.
#
# The levers are named A/B/C below for the hypotheses they were built to test.
# A and B -- a release armed while a query is live, surviving the close, and
# firing on the NEXT open -- are NOT SUPPORTED: no divergence line appears after
# any "reopen no query" marker, on either build. The close animation renders, so
# the armed entries start and expire before the overview is gone.
set -u
source "$HOME/overview-cpp/scripts/lib/rig.sh"
rig_env || exit 1

OUT=/mnt/host/zrig/fire-phantom; mkdir -p $OUT
LOG=$HOME/.local/state/hyprdrive/membership-shadow.log
TAG=${1:-promo}
FX=835; FY=525; FW=890; FH=550

restore() { ov off; dsp 'hl.dsp.focus({workspace = 1})'; hyprwall_resume; }
trap restore EXIT

hyprwall_pause
ov off; sleep 1
pkill -x kitty 2>/dev/null; sleep 1.5

spawn_on() { dsp "hl.dsp.focus({workspace = $1})"; sleep 0.4; fixture_kitty "$2" $FX $FY $FW $FH "${3:-#101820}" 'sleep 3600'; }
marker() { printf 'MARK %s\n' "$1" >> "$LOG"; }
focus_cls() { dsp "hl.dsp.focus({window = [[class:$1]]})"; sleep 0.4; }
type_q() { ydotool type "$1"; sleep 1.0; }
clear_q() { for _ in $(seq 1 "${1:-6}"); do ydotool key 14:1 14:0; sleep 0.10; done; sleep 0.8; }

spawn_on 3 PHANAWAY '#101820' || exit 1
spawn_on 5 PHANHOME '#182028' || exit 1
spawn_on 5 PHANMIN  '#203040' || exit 1

# PHANMIN minimized FROM ws5 -- so its HOME is the active desktop and its
# m_workspace is the stash. That is lever C's fixture.
focus_cls PHANMIN
dsp "hl.plugin.$RIG_NS.minimize([[window]])"; sleep 1.6
dsp 'hl.dsp.focus({workspace = 5})'; sleep 1.0

echo "=== state ==="
hyprctl clients -j | python3 -c "
import json,sys
for c in sorted(json.load(sys.stdin), key=lambda c: str(c['workspace']['id'])):
    if c['class'].startswith('PHAN'):
        print(f\"{c['class']:10s} ws{str(c['workspace']['id']):>5} {c['workspace']['name']:<20} mapped={c['mapped']} hidden={c['hidden']}\")"
echo "active: $(hyprctl activeworkspace -j | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')"

BASE=$(grep -c '^RENDER-' "$LOG" 2>/dev/null || echo 0)

# ---- lever C: query with a minimized window homed on the active desktop -----
marker "C: open, query PHAN (minimized PHANMIN homed here)"
ov on; sleep 2.2
grim "$OUT/$TAG-C-noquery.png"
type_q 'PHAN'
sleep 1.5
grim "$OUT/$TAG-C-query.png"

# ---- lever A: close the overview WITH the query still live ------------------
marker "A: closing overview with the query still live"
ov off; sleep 2.0

# ---- lever B: reopen with no query -----------------------------------------
marker "B: reopen, no query"
ov on; sleep 0.4
grim "$OUT/$TAG-B-reopen-early.png"
sleep 2.0
grim "$OUT/$TAG-B-reopen-settled.png"
marker "B: settled"
sleep 1.0
ov off; sleep 1.8

# ---- repeat the cycle: the doctrine is cycles, not one shot -----------------
for lap in 1 2 3; do
    marker "cycle lap $lap open"
    ov on; sleep 1.8
    type_q 'PHAN'
    sleep 1.2
    marker "cycle lap $lap close with query live"
    ov off; sleep 1.8
    marker "cycle lap $lap reopen no query"
    ov on; sleep 0.35
    grim "$OUT/$TAG-lap$lap-early.png"
    sleep 1.8
    ov off; sleep 1.6
done

marker "soak2 end"
cp -f "$LOG" "$OUT/$TAG-shadow.log" 2>/dev/null
echo
echo "=== render divergence kinds (whole log) ==="
grep -oE '^RENDER-[A-Z]+' "$LOG" 2>/dev/null | sort | uniq -c
echo "=== first 25 divergence lines ==="
grep -E '^RENDER-(GHOST|PROMONOQ|GRIDDUP|STALE|MISSING|DUP|CROSS)' "$LOG" 2>/dev/null | head -25
echo "=== membership cache ==="
grep -c '^DIVERGE' "$LOG" 2>/dev/null | sed 's/^/DIVERGE lines: /'
grep -E '^REPORT' "$LOG" | tail -2
echo FIRE_PROMO_OK
