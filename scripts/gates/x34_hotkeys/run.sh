#!/usr/bin/env bash
# Gate x34_hotkeys -- OVERVIEW_CPP_SPEC 13.9: Super+1..0 dock hotkeys (slot ten
# = the 0 key), Shift/Ctrl families, <Super>q overlay at the 2.0s timeout.
# State claims (minimized sets, class counts, launches) are asserted by the rig
# itself as PASS/FAIL verdict lines; pixel claims (overlay triples, circle
# count, slot-ten ink, showdock, hot_keys=false) go through x34_gate.py.
# GUEST-side, end to end. Exit 0 iff green.
#
# Orchestration reconstructed from the rig's P1..P9 phase comments and the
# gate's command signatures: the pill box is MEASURED once per seed (the
# 11-favourite pill is wider than the 3-favourite one) and fed to every pixel
# grader; P1-P6 run on seed3 (slot 9 must be empty), P7-P9 on seed11.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh
rig_env || exit 1

OUT=/mnt/host/x34shots
STORE=$HOME/.local/state/scrolloverview/favorites

# x34_gate.py hardcodes the HOST's view of the share (/home/dragos/hyprvm/share);
# grading now runs in the guest, where the share is /mnt/host. Alias, never edit
# the grader.
if [ ! -e /home/dragos/hyprvm/share ]; then
    mkdir -p /home/dragos/hyprvm
    ln -sfn /mnt/host /home/dragos/hyprvm/share || exit 1
fi

# The seeds overwrite the favourites store; put the user's own back afterwards.
FAV_BAK=
[ -f "$STORE" ] && { FAV_BAK=$(mktemp); cp "$STORE" "$FAV_BAK"; }
cleanup() {
    if [ -n "$FAV_BAK" ] && [ -f "$FAV_BAK" ]; then
        mkdir -p "$(dirname "$STORE")"; cp "$FAV_BAK" "$STORE"; rm -f "$FAV_BAK"
    else
        rm -f "$STORE"
    fi
    headless_off
    hyprwall_resume
}

hyprwall_pause
# Pixel phases need live frames; a detached Virtual-1 draws ~1fps and hands grim
# stale frames, and the overlay triples would then FAIL as "output stalled".
headless_on || exit 1
trap cleanup EXIT

# The X34 binds (host D2D layout; unbinds ii's SUPER+digit / SUPER+Q first).
# The rig dispatches hotkey() directly, so the gate does not depend on these,
# but the DoD's "binds stay" arrangement is loaded exactly as how_to_run says.
hl "$(cat scripts/x34_binds.lua)
return 0" >/dev/null || { echo "X34: loading x34_binds.lua failed"; exit 1; }

RIGOUT=
phase() { # phase <phase> [tag] -- run one rig phase; fail on rc!=0 or a FAIL verdict
    echo "== x34_rig $*"
    RIGOUT=$(bash scripts/x34_rig.sh "$@" 2>&1)
    local rc=$?
    printf '%s\n' "$RIGOUT"
    [ "$rc" = 0 ] || return 1
    printf '%s\n' "$RIGOUT" | grep -q '^FAIL ' && return 1
    return 0
}
vphase() { # a phase that must ALSO print an explicit PASS verdict
    phase "$@" || return 1
    printf '%s\n' "$RIGOUT" | grep -q '^PASS ' \
        || { echo "X34: phase $1 printed no verdict"; return 1; }
}
gate() { echo "== x34_gate $*"; python3 scripts/x34_gate.py "$@"; }
X0= Y0= X1= Y1=
pillbox() { # measure the pill for TAG; leaves the box in X0 Y0 X1 Y1
    local out
    out=$(gate pill "$1") || { printf '%s\n' "$out"; return 1; }
    printf '%s\n' "$out"
    read -r X0 Y0 X1 Y1 <<< "$(printf '%s\n' "$out" \
        | sed -n 's/^PILL x0=\([0-9]*\) y0=\([0-9]*\) x1=\([0-9]*\) y1=\([0-9]*\).*/\1 \2 \3 \4/p')"
    [ -n "$X0" ] || { echo "X34: could not parse the pill box"; return 1; }
}

# --- seed3 arm: hotkey STATE + overlay/empty triples -------------------------
phase seed3          || exit 1
phase fixture        || exit 1
alive_or_die "after fixture"
phase pill p3        || exit 1
pillbox p3           || exit 1
vphase slot1         || exit 1
vphase slot1shift    || exit 1
vphase slot2         || exit 1
vphase ctrl1         || exit 1
alive_or_die "after hotkey state phases"
phase overlay ov3    || exit 1
gate overlay ov3 "$X0" "$Y0" "$X1" "$Y1" || exit 1
vphase empty em3     || exit 1
gate overlay em3 "$X0" "$Y0" "$X1" "$Y1" || exit 1

# --- seed11 arm: circle cap, slot-ten ink, showdock, hot_keys=false ----------
phase seed11         || exit 1
phase fixture        || exit 1
phase pill p11       || exit 1
pillbox p11          || exit 1
phase ten t11        || exit 1
gate count t11 "$X0" "$Y0" "$X1" "$Y1" 10 || exit 1
gate ink   t11 "$X0" "$Y0" "$X1" "$Y1"    || exit 1
phase showdock sd11  || exit 1
gate showdock sd11 "$X0" "$Y0" "$X1" "$Y1" || exit 1
vphase off off11     || exit 1
gate off off11 "$X0" "$Y0" "$X1" "$Y1" || exit 1
alive_or_die "at the end of the run"

echo X34_GATE_GREEN
exit 0
