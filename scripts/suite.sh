#!/usr/bin/env bash
# Run every promoted gate under scripts/gates/. One PASS/FAIL line per gate,
# a summary table, nonzero exit on any red. A gate is a directory holding a
# run.sh that exits 0 on green -- everything else about it is the gate's own
# business. Filter to a subset with: suite.sh z-suite dock-click
set -u
cd "$(dirname "$0")/.."

RED=$'\033[31m'; GRN=$'\033[32m'; NC=$'\033[0m'
declare -a NAMES; declare -A RES SECS
fail=0

for dir in scripts/gates/*/; do
    name=$(basename "$dir")
    if [ $# -gt 0 ]; then
        keep=0; for want in "$@"; do [ "$name" = "$want" ] && keep=1; done
        [ $keep = 1 ] || continue
    fi
    [ -x "$dir/run.sh" ] || { echo "SKIP $name (no run.sh)"; continue; }
    t0=$SECONDS
    if "$dir/run.sh" >"$dir/last.log" 2>&1; then
        RES[$name]=PASS
    elif [ $? -eq 3 ]; then
        RES[$name]=SKIP    # NEEDS-HOST: gate documents why in its log
    else
        RES[$name]=FAIL; fail=1
    fi
    SECS[$name]=$((SECONDS - t0))
    NAMES+=("$name")
    c=$GRN; [ "${RES[$name]}" = FAIL ] && c=$RED
    printf '%s%-24s %s  %4ss%s\n' "$c" "$name" "${RES[$name]}" "${SECS[$name]}" "$NC"
done

echo
printf '== %d gates, %d failed\n' "${#NAMES[@]}" "$(for n in "${NAMES[@]}"; do echo "${RES[$n]}"; done | grep -c FAIL)"
[ $fail = 0 ]
