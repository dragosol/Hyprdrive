#!/usr/bin/env bash
# Run every promoted gate under scripts/gates/. One PASS/FAIL line per gate,
# a summary table, nonzero exit on any red. A gate is a directory holding a
# run.sh that exits 0 on green -- everything else about it is the gate's own
# business. Filter to a subset with: suite.sh z-suite dock-click
#
# Two things here are not bookkeeping and must not be dropped:
#
#   SLATE   the session is put back to a known state BEFORE each gate
#           (gate_slate in lib/rig.sh). Gates leave fixtures mapped, dock
#           options flipped, headless outputs behind and the overview open;
#           without this the table reads gate N+1 and reports gate N.
#
#   DIED    the compositor's instance signature is compared across each gate.
#           gdm's autologin restarts Hyprland in about two seconds, so a
#           compositor that dies mid-suite is INVISIBLE to a runner that only
#           looks at exit codes -- the remaining gates just quietly measure a
#           different session. On 2026-08-11 that turned one crash in g5 into
#           "25 of 27 gates fail" and hid it behind two dozen plausible-looking
#           red pixel verdicts. A gate that killed the compositor is a FAIL,
#           says so by name, and the suite waits for the session to come back
#           before it slates the next one.
set -u
cd "$(dirname "$0")/.."
source scripts/lib/rig.sh
rig_env || exit 1

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; NC=$'\033[0m'
declare -a NAMES; declare -A RES SECS
fail=0

# hyprwall is held down for the WHOLE run, once. The per-gate pause/resume pairs
# the gates ship were re-arming the rotation between gates -- and `systemctl
# start` on an OnActiveSec=3min timer is itself a rotation trigger.
export RIG_HYPRWALL_HELD=1
hyprwall_pause 180min
trap 'RIG_HYPRWALL_HELD=0; hyprwall_resume' EXIT

for dir in scripts/gates/*/; do
    name=$(basename "$dir")
    if [ $# -gt 0 ]; then
        keep=0; for want in "$@"; do [ "$name" = "$want" ] && keep=1; done
        [ $keep = 1 ] || continue
    fi
    [ -x "$dir/run.sh" ] || { echo "SKIP $name (no run.sh)"; continue; }

    t0=$SECONDS
    if ! gate_slate "$name" >"$dir/slate.log" 2>&1; then
        RES[$name]=SLATE; fail=1
    else
        SIG_BEFORE=$(rig_sig)
        "$dir/run.sh" >"$dir/last.log" 2>&1; rc=$?
        RESTARTED=0
        [ "$(rig_sig)" != "$SIG_BEFORE" ] && RESTARTED=1
        if [ $RESTARTED = 1 ]; then
            # Re-discover either way: our own exported instance signature now
            # points at a dead socket, and gate_slate is the next thing to use it.
            rig_wait_session || { echo "SUITE: the session did not come back; aborting" >&2; break; }
        fi
        # x51 restarts the compositor ON PURPOSE (it needs a cold glyph cache)
        # and says so with a marker file. Every other gate that comes back on a
        # different instance killed it, and everything it printed is void --
        # including a PASS.
        if [ $RESTARTED = 1 ] && [ ! -e "$dir/restarts-compositor" ]; then
            RES[$name]=DIED; fail=1
            echo "SUITE: the compositor died during $name -- everything above is void" >>"$dir/last.log"
        elif [ $rc -eq 0 ]; then
            RES[$name]=PASS
        elif [ $rc -eq 3 ]; then
            RES[$name]=SKIP    # NEEDS-HOST: gate documents why in its log
        else
            RES[$name]=FAIL; fail=1
        fi
    fi
    SECS[$name]=$((SECONDS - t0))
    NAMES+=("$name")
    case "${RES[$name]}" in FAIL|SLATE) c=$RED ;; DIED) c=$YEL ;; *) c=$GRN ;; esac
    printf '%s%-24s %-5s %4ss%s\n' "$c" "$name" "${RES[$name]}" "${SECS[$name]}" "$NC"
done

echo
printf '== %d gates, %d red\n' "${#NAMES[@]}" \
    "$(for n in "${NAMES[@]}"; do echo "${RES[$n]}"; done | grep -cE 'FAIL|DIED|SLATE')"
[ $fail = 0 ]
