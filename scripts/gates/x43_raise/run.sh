#!/usr/bin/env bash
# Gate x43_raise -- clicking an overview tile RAISES the window, decided by
# PIXELS at the geometric overlap of two flat-colour windows, never focus (X43
# was closed three times on a focus assertion while still broken).
# GUEST-side, end to end: fixture -> overview capture -> locate the RED tile ->
# held click with sub-threshold jitter -> pixel gate on post.png. Exit 0 iff
# the RED (BOT) window owns the overlap afterwards.
#
# The headless swap lives HERE (rig.sh headless_on + chained trap) rather than
# in x43_fixture.sh, because the teardown must outlive the fixture script --
# open/click still need the headless output after it exits.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

OUT=/mnt/host/x43

hyprwall_pause
headless_on || exit 1
trap 'headless_off; hyprwall_resume' EXIT

bash scripts/x43_fixture.sh || { echo "X43: fixture failed"; exit 1; }
alive_or_die "after fixture"
bash scripts/x43_open.sh    || { echo "X43: overview capture failed"; exit 1; }

# Locate the RED (BOT) tile in the overview capture. PIL+numpy run in the guest.
TB=$(python3 scripts/x43_tilebox.py "$OUT/ovr.png" red) \
    || { printf '%s\n' "$TB"; echo "X43: red tile not located"; exit 1; }
printf '%s\n' "$TB"
read -r GX GY <<< "$(printf '%s\n' "$TB" | sed -n 's/^GX=\([0-9]*\) GY=\([0-9]*\)$/\1 \2/p')"
[ -n "${GX:-}" ] && [ -n "${GY:-}" ] || { echo "X43: no GX/GY in tilebox output"; exit 1; }

bash scripts/x43_click.sh "$GX" "$GY" || { echo "X43: click failed"; exit 1; }
alive_or_die "after the click"

# `bot`: the clicked (red, underneath) window must own the overlap afterwards.
# Without this expectation argument the grader reports and always exits 0.
python3 scripts/x43_gate.py "$OUT/post.png" "$OUT/fixture-clients.json" bot || exit 1

echo X43_GATE_GREEN
exit 0
