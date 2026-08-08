#!/usr/bin/env bash
# GATE fade_alpha -- the chrome fade factor actually modulates alpha. Rebuild-
# heavy BY DESIGN (fade_alpha_gate.py header): the plugin must be built once
# with FADE forced to 0.5 and once stock, each build loaded into the compositor
# (GDM restart) and captured with scripts/settled_shot.sh over the x48 fixture
# with the wallpaper pinned:
#     bash scripts/settled_shot.sh full     # stock build   -> full-settled.png
#     bash scripts/settled_shot.sh half     # FADE=0.5 build -> half-settled.png
# This wrapper cannot rebuild or reload the plugin from inside the guest, so it
# grades the two captures when they exist and exits 3 (NEEDS-HOST) otherwise --
# an honest skip beats a fake pass. FRESHNESS of the captures is the operator's
# responsibility; the mtimes are printed so a stale pair is at least visible.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"

FULL=${FADE_FULL:-/mnt/host/fade/full-settled.png}
HALF=${FADE_HALF:-/mnt/host/fade/half-settled.png}

if [ -s "$FULL" ] && [ -s "$HALF" ]; then
    echo "grading existing captures (verify these are from the CURRENT build pair):"
    ls -l "$FULL" "$HALF"
    python3 scripts/fade_alpha_gate.py "$FULL" "$HALF"
    exit $?
fi

echo "NEEDS-HOST: fade_alpha requires two plugin BUILDS (stock and FADE forced to 0.5)," >&2
echo "each loaded via a compositor restart and captured with scripts/settled_shot.sh" >&2
echo "(x48 fixture up first; the tool pins the wallpaper itself). Missing:" >&2
[ -s "$FULL" ] || echo "  $FULL   (capture: bash scripts/settled_shot.sh full, on the stock build)" >&2
[ -s "$HALF" ] || echo "  $HALF   (capture: bash scripts/settled_shot.sh half, on the FADE=0.5 build)" >&2
echo "Then re-run this gate to grade them." >&2
exit 3
