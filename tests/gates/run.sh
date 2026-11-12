#!/usr/bin/env bash
# tests/gates/run.sh -- run the behaviour gates on the headless rig.
#
#   tests/gates/run.sh [--so PATH] [--control [--control-so PATH]] [--keep] [--list] [name...]
#
# Builds nothing. Each gate is tests/gates/<name>.sh (plus the older
# own_size_tile/run.sh, as `own_size_tile`), runs in its own rig instance
# (HL_NAME=g<tag>, hl.sh as user hyprtest via sudo -n), and prints ONE line:
#
#   PASS|FAIL|KNOWN-FAIL|SKIP  <name>  <seconds>s  <reason>
#
#   --so PATH   the hyprdrive.so under test (default: the tree's hyprdrive.so).
#               It is copied ONCE into a hyprtest-readable /tmp dir, so no gate
#               stages its own 240 MB copy.
#   --control   run each gate's CONTROL instead (the feature's option off, or a
#               build with the bug via --control-so): PASS then means
#               "the control failed as it must", FAIL means the gate is blind.
#   --control-so PATH  the build with the bug, for the gates whose control is a
#               build (fs_move_close, display_compact, x11_state: 8bb258c;
#               overview_rest: a4d6892); without
#               it those gates SKIP in a --control run
#   --keep      keep every gate's log (default: only those that did not PASS)
#   --list      the gates and the first line of their header
#
# Exit status: 1 if any gate FAILED (KNOWN-FAIL and SKIP do not fail the run).
# Logs: $GATES_OUT (default /tmp/hdg-run.<pid>/<name>.log). /tmp is RAM: the
# gates keep their captures small and delete them when they pass.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SO=$ROOT/hyprdrive.so; CONTROL=0; CSO=; KEEP=0; names=()
while [ $# -gt 0 ]; do case $1 in
    --so) SO=$2; shift ;;
    --control) CONTROL=1 ;;
    --control-so) CSO=$2; shift ;;
    --keep) KEEP=1 ;;
    --list)
        for f in "$HERE"/*.sh; do n=$(basename "$f" .sh); case $n in lib|run) continue ;; esac
            printf '%-16s %s\n' "$n" "$(sed -n '2s/^# *[a-z0-9_]* -- //p' "$f" | cut -c1-100)"; done
        printf '%-16s %s\n' own_size_tile "Super+T own-size tiles (older gate, own runner)"; exit 0 ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d'; exit 0 ;;
    -*) echo "run.sh: unknown option $1" >&2; exit 2 ;;
    *) names+=("$1") ;;
esac; shift; done
case $SO in /*) ;; *) SO=$PWD/$SO ;; esac
[ -f "$SO" ] || { echo "run.sh: no .so at $SO (build first: make)" >&2; exit 2; }
sudo -n -u hyprtest true 2>/dev/null || { echo "run.sh: needs passwordless sudo to user hyprtest (the rig user)" >&2; exit 2; }

if [ ${#names[@]} = 0 ]; then
    for f in "$HERE"/*.sh; do n=$(basename "$f" .sh); case $n in lib|run) ;; *) names+=("$n") ;; esac; done
    names+=(own_size_tile)
fi

OUT=${GATES_OUT:-/tmp/hdg-run.$$}; mkdir -p "$OUT"
SOD=$(mktemp -d /tmp/hdg-so.XXXX); chmod 755 "$SOD"
install -m644 "$SO" "$SOD/hyprdrive.so"
if [ -n "$CSO" ]; then case $CSO in /*) ;; *) CSO=$PWD/$CSO ;; esac; install -m644 "$CSO" "$SOD/control.so"; CSO=$SOD/control.so; fi
cleanup() { rm -rf "$SOD"; rmdir "$OUT" 2>/dev/null || true; }
trap cleanup EXIT

echo "gates: $(basename "$(dirname "$SO")")/$(basename "$SO") $(sha256sum "$SO" | cut -c1-12)$([ $CONTROL = 1 ] && echo ', CONTROL runs')"
fails=0; t_all=$(date +%s)
for n in "${names[@]}"; do
    t0=$(date +%s); log=$OUT/$n.log
    if [ "$n" = own_size_tile ]; then
        if [ $CONTROL = 1 ]; then printf '%-10s %-22s %4ss  %s\n' SKIP "$n" 0 "its control runs inside the gate"; continue; fi
        HL_NAME=gown bash "$HERE/own_size_tile/run.sh" "$SOD/hyprdrive.so" > "$log" 2>&1; rc=$?
        sudo -n -u hyprtest rm -rf /tmp/hl-gown 2>/dev/null
        if [ $rc = 0 ]; then res="PASS $(grep -c '^ok' "$log") checks"; else res="FAIL $(grep -m1 '^FAIL' "$log")"; fi
    elif [ -f "$HERE/$n.sh" ]; then
        GATE_SO=$SOD/hyprdrive.so GATE_CONTROL=$CONTROL GATE_CONTROL_SO=$CSO GATE_OUT=$OUT/$n.d timeout 300 bash "$HERE/$n.sh" > "$log" 2>&1; rc=$?
        res=$(sed -n 's/^RESULT //p' "$log" | tail -1)
        [ -n "$res" ] || res="FAIL no verdict (exit $rc$([ $rc = 124 ] && echo ', timed out'))"
    else
        res="FAIL no such gate"
    fi
    verdict=${res%% *}; reason=${res#* }
    printf '%-10s %-22s %4ss  %s\n' "$verdict" "$n" $(( $(date +%s) - t0 )) "$reason"
    [ "$verdict" = FAIL ] && fails=$((fails + 1))
    [ "$verdict" = PASS ] && [ $KEEP = 0 ] && rm -rf "$log" "$OUT/$n.d"
done
echo "gates: ${#names[@]} run, $fails failed, $(( $(date +%s) - t_all ))s$( [ -n "$(ls -A "$OUT" 2>/dev/null)" ] && echo ", logs in $OUT")"
[ $fails = 0 ]
