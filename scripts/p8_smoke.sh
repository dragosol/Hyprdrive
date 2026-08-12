#!/usr/bin/env bash
# Phase 8 manual drag smoke, FILMED. Runs IN THE GUEST.
#
# The three drags a human would try after this phase touched endWindowDrag:
# a tile onto another desktop, a tile onto the dock (minimize), and a near miss
# just above the pill that must do nothing. Filmed rather than screenshotted --
# a one-shot grim on this guest returns a stale frame, and the point here is the
# MOTION between the press and the drop, not the endpoints the A/B already
# compares.
#
# Films and the resulting geometry land in /mnt/host/zrig/phase8/smoke/.
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1

OUT=/mnt/host/zrig/phase8/smoke
rm -rf "$OUT"; mkdir -p "$OUT"

export RIG_HYPRWALL_HELD=1
hyprwall_pause 30min
headless_on || exit 1
trap 'headless_off; RIG_HYPRWALL_HELD=0; hyprwall_resume' EXIT

read -r GX GY MX MY PCX PTOP < /mnt/host/zrig/phase8/points

fixture() {
    pkill -9 kitty >/dev/null 2>&1
    sleep 1.0
    dsp "hl.dsp.focus({workspace = 2})"; sleep 0.4
    fixture_kitty p8blue 300 300 900 600 "#0000ff" || return 1
    dsp "hl.dsp.focus({workspace = 1})"; sleep 0.4
    fixture_kitty p8green 200 200 900 600 "#00ff00" || return 1
    sleep 0.6
    ov on
    sleep 2.0
}

film() { # film NAME TX TY
    local name=$1 tx=$2 ty=$3 i
    fixture || exit 1

    rm -f "$OUT/$name.mp4"
    wf-recorder -o "$RIG_MON" -f "$OUT/$name.mp4" -c libvpx-vp9 -r 30 > "$OUT/$name-wfr.log" 2>&1 &
    local WFR=$!
    sleep 2.5

    warp "$GX" "$GY"; sleep 0.5
    ydotool click 0x40
    sleep 0.3
    for i in $(seq 1 24); do warp $(( GX + (tx - GX) * i / 24 )) $(( GY + (ty - GY) * i / 24 )); sleep 0.06; done
    warp "$tx" "$ty"
    sleep 1.0
    ydotool click 0x80
    sleep 2.5

    kill -INT $WFR 2>/dev/null; wait $WFR 2>/dev/null
    hyprctl clients -j > "$OUT/$name-clients.json"
    alive_or_die "after the $name smoke"
    ov_off_settled
    printf '%-10s %s bytes\n' "$name" "$(stat -c %s "$OUT/$name.mp4" 2>/dev/null || echo 0)"
}

film desktop "$MX" "$MY"                  # onto desktop 2's strip cell
film minimize "$PCX" $(( PTOP + 39 ))     # onto the dock pill
film nearmiss "$PCX" $(( PTOP - 28 ))     # 28 px above it: must do nothing

python3 - "$OUT" <<'PY'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1])
for name in ("desktop", "minimize", "nearmiss"):
    rows = []
    for c in sorted(json.load(open(d / f"{name}-clients.json")), key=lambda c: c["class"]):
        if c["class"].startswith("p8"):
            rows.append(f"{c['class']} ws={c['workspace']['id']} at={c['at']} size={c['size']}")
    print(f"{name:<10}", "; ".join(rows))
PY
echo P8_SMOKE_OK
