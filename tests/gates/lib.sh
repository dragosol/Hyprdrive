# tests/gates/lib.sh -- shared helpers for the behaviour gates (sourced, never run).
#
# A gate is tests/gates/<name>.sh. It sources this file, calls `gate_begin`,
# drives one headless rig instance (tests/rig/headless/hl.sh, user hyprtest)
# and ends with `gate_end`, which prints the verdict line the runner reads:
#
#   RESULT PASS|FAIL|KNOWN-FAIL|SKIP <reason>
#
# Exit status: 0 PASS, 1 FAIL, 77 SKIP, 78 KNOWN-FAIL (only known failures).
#
# Environment (set by tests/gates/run.sh; a gate also runs alone with defaults):
#   GATE_SO       absolute path of the hyprdrive.so under test (default: the tree's)
#   GATE_CONTROL  1 = run the gate's CONTROL variant (the feature's option off, or a
#                 build with the bug): the gate's checks must then FAIL
#   GATE_OUT      a directory for this gate's small evidence files (kept on FAIL)
#   HL_NAME       the rig instance name (default g<gate tag>); always starts with g
#
# Rig rules kept here so no gate can forget them: every compositor command goes
# through hl.sh (or `hq`, the same hyprctl as user hyprtest pinned to THIS
# instance's runtime dir and signature -- it can never reach the owner's
# session); fixtures are kitty with an explicit size; processes are only ever
# killed by hl.sh stop (by PID); the instance is stopped and /tmp/hl-<name>
# removed when the gate ends, also on failure (trap).

set -u
GATES_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$GATES_DIR/../.." && pwd)
R=$ROOT/tests/rig/headless/hl.sh
SO=${GATE_SO:-$ROOT/hyprdrive.so}
CONTROL=${GATE_CONTROL:-0}
K="kitty -o remember_window_size=no -o initial_window_width=900 -o initial_window_height=600"
SU() { sudo -n -u hyprtest "$@"; }

_fails=0; _known=0; _checks=0; _first_fail=; _first_known=; _started=0; _skips=

# gate_begin TAG -- instance name g<TAG>, evidence dir, cleanup trap
gate_begin() {
    GATE_TAG=$1
    export HL_NAME=${HL_NAME:-g$GATE_TAG}
    case $HL_NAME in g*) ;; *) echo "RESULT FAIL HL_NAME must start with g"; exit 1 ;; esac
    ST=/tmp/hl-$HL_NAME; RT=$ST/rt
    TRACE=$RT/hyprdrive-mosaic.log; REFUSED=$RT/hyprdrive-desktops.log
    GOUT=${GATE_OUT:-/tmp/hdg-$HL_NAME}; mkdir -p "$GOUT"; chmod 755 "$GOUT"
    trap _gate_cleanup EXIT
    trap 'exit 130' INT TERM
}

_gate_cleanup() {
    [ "$_started" = 1 ] && rig_stop >/dev/null 2>&1
    SU rm -rf "/tmp/hl-$HL_NAME" 2>/dev/null || true
    # samplers we started (our own PIDs only)
    for p in ${_bg_pids:-}; do kill "$p" 2>/dev/null || true; done
}

# rig_start [hl.sh start args...] -- a fresh instance with $SO loaded (unless --no-plugin)
rig_start() {
    $R stop >/dev/null 2>&1 || true
    local a=(--so "$SO"); for x in "$@"; do [ "$x" = --no-plugin ] && a=(); done
    # a config that loads the plugin itself: hl.sh must not load one more
    case " $* " in *" --config "*) a=(--no-plugin) ;; esac
    if ! $R start "${a[@]}" "$@" > "$GOUT/start.log" 2>&1; then
        echo "rig start failed:"; tail -5 "$GOUT/start.log"; echo "RESULT FAIL rig did not start"; exit 1
    fi
    _started=1
    SIG=$(SU cat "$ST/sig")
    # the path Hyprland loaded (hl.sh stages a copy when hyprtest cannot read $SO)
    if SU test -r "$SO"; then LOADED=$SO; else LOADED=$ST/staged/$(basename "$SO"); fi
}

# rig_stop -- stops the instance; sets CORES=1 if hl.sh reported a core of it
rig_stop() {
    local out rc=0
    out=$($R stop 2>&1) || rc=$?
    _started=0
    CORES=0; [ $rc = 3 ] && CORES=1
    echo "$out" | tail -3 > "$GOUT/stop.log"
    return 0
}

# hq <hyprctl args> -- hyprctl against THIS instance, one sudo, no restaging
hq() { SU env XDG_RUNTIME_DIR="$RT" HYPRLAND_INSTANCE_SIGNATURE="$SIG" hyprctl "$@"; }
ev() { hq eval "$*" >/dev/null; }
dbg() { hq dispatch "hl.plugin.hyprdrive.debug(\"$*\")" 2>&1; }   # a topic's report
trace_on() { SU touch "$RT/hyprdrive-mosaic.on"; sleep 1.1; }       # read once a second
trace() { SU cat "$TRACE" 2>/dev/null; }
refused() { SU cat "$REFUSED" 2>/dev/null; }
hlog() { $R log "${1:-400}"; }

# ---------------------------------------------------------------- results
# check NAME OK(1|other) DETAIL [KNOWN reason] -- one line per check
check() {
    _checks=$((_checks + 1))
    if [ "$2" = 1 ]; then
        echo "ok    $1"
        [ $# -ge 4 ] && echo "      (marked known-fail but PASSES now: $4 -- drop the mark)"
    elif [ $# -ge 4 ]; then
        echo "KNOWN $1 ($3) -- $4"; _known=$((_known + 1)); [ -n "$_first_known" ] || _first_known="$1: $4"
    else
        echo "FAIL  $1 ($3)"; _fails=$((_fails + 1)); [ -n "$_first_fail" ] || _first_fail="$1: $3"
    fi
}
is() { [ "$1" = "$2" ] && echo 1 || echo 0; }                 # is A B -> 1 when equal
le() { [ "$1" -le "$2" ] 2>/dev/null && echo 1 || echo 0; }   # le A B
ge() { [ "$1" -ge "$2" ] 2>/dev/null && echo 1 || echo 0; }

skip() { echo "RESULT SKIP $*"; exit 77; }
# subskip NAME REASON -- one check that cannot apply to this build; named in the verdict
subskip() { echo "SKIP  $1 ($2)"; _skips="${_skips:+$_skips; }$1: $2"; }

gate_end() {
    if [ "$_started" = 1 ]; then rig_stop; check "no core dump of the instance" "$(is "$CORES" 0)" "$(cat "$GOUT/stop.log" | head -2 | tr '\n' ' ')"; fi
    if [ "$CONTROL" = 1 ]; then
        # a control run is SUPPOSED to fail: report it as such, exit 0 only if it did
        if [ $((_fails + _known)) -gt 0 ]; then echo "RESULT PASS control failed as it must: ${_first_fail:-$_first_known}"; exit 0; fi
        echo "RESULT FAIL control did NOT fail: the gate cannot see the bug"; exit 1
    fi
    if [ $_fails -gt 0 ]; then echo "RESULT FAIL $_fails/$_checks: $_first_fail"; exit 1; fi
    SU rm -rf "$GOUT" 2>/dev/null; rm -rf "$GOUT" 2>/dev/null
    if [ $_known -gt 0 ]; then echo "RESULT KNOWN-FAIL $_first_known"; exit 78; fi
    echo "RESULT PASS $_checks checks${_skips:+ (skipped: $_skips)}"; exit 0
}

# ---------------------------------------------------------------- state
J() { hq -j "$@"; }
# ids: "id:windows" of every desktop, sorted ("1:2 2:1 3:1")
ids() { J workspaces | jq -r '[.[] | select(.id > 0) | "\(.id):\(.windows)"] | sort_by(split(":")[0]|tonumber) | join(" ")'; }
# pop: the populated desktops ("1 2 3")
pop() { J workspaces | jq -r '[.[] | select(.id > 0 and .windows > 0) | .id] | sort | map(tostring) | join(" ")'; }
uniq_ok() { J workspaces | jq -e '[.[] | select(.id > 0) | .id] | (length == (unique | length)) and all(. >= 1)' >/dev/null; }
addr() { J clients | jq -r ".[] | select(.workspace.id == $1) | .address" | sed -n "${2:-1}p"; }
addr_of() { J clients | jq -r ".[] | select(.class == \"$1\") | .address" | head -1; }
# win CLASS [FIELD] -- one jq field of a client by class (default: the whole object)
win() { J clients | jq -c ".[] | select(.class == \"$1\") | ${2:-.}" | head -1; }
nclients() { J clients | jq length; }
shown() { J monitors | jq -r ".[] | select(.name == \"${1:-HEADLESS-1}\") | .activeWorkspace.id"; }
go() { ev "hl.dispatch(hl.dsp.focus({ workspace = \"$1\" }))"; }
fs() { ev "hl.dispatch(hl.dsp.window.fullscreen({ window = [[address:$1]], action = \"$2\" }))"; }
focus() { ev "hl.dispatch(hl.dsp.focus({ window = [[address:$1]] }))"; }
close_win() { ev "hl.dispatch(hl.dsp.window.close({ window = [[address:$1]] }))"; }
move_to() { ev "hl.dispatch(hl.dsp.window.move({ window = [[address:$1]], workspace = \"$2\" }))"; }
cfg() { ev "hl.config($*)"; }

# kw CLASS [W H] -- a kitty fixture of an explicit size; waits until it is mapped
kw() {
    local w=${2:-900} h=${3:-600} n0; n0=$(nclients)
    $R win kitty -o remember_window_size=no -o initial_window_width="$w" -o initial_window_height="$h" --class "$1" >/dev/null
    wait_for 5 "[ \$(J clients | jq '[.[] | select(.class == \"$1\")] | length') -ge 1 ]" || echo "warn: $1 never mapped"
}
# kexec CLASS [W H] -- the same, launched by the compositor (hl.dsp.exec_cmd), as an app would open it
kexec() {
    local w=${2:-900} h=${3:-600}
    ev "hl.dispatch(hl.dsp.exec_cmd(\"kitty -o remember_window_size=no -o initial_window_width=$w -o initial_window_height=$h --class $1\"))"
    wait_for 5 "[ -n \"\$(addr_of $1)\" ]" || echo "warn: $1 never mapped"
}

# wait_for SECONDS 'shell condition' -- poll every 0.1 s; 0 when it held
wait_for() {
    local end=$(( $(date +%s%N) + ${1%.*} * 1000000000 ))
    while [ "$(date +%s%N)" -lt $end ]; do eval "$2" 2>/dev/null && return 0; sleep 0.1; done
    return 1
}
# settle SECONDS CMD -- wait until CMD's output stops changing for 0.6 s (max SECONDS)
settle() {
    local end=$(( $(date +%s%N) + ${1%.*} * 1000000000 )) last= now same=0
    while [ "$(date +%s%N)" -lt $end ]; do
        now=$(eval "$2" 2>/dev/null)
        if [ "$now" = "$last" ]; then same=$((same + 1)); [ $same -ge 6 ] && return 0; else same=0; last=$now; fi
        sleep 0.1
    done
    return 1
}
# geom: "class x,y wxh" of every client, sorted -- the "windows untouched" fingerprint
geom() { J clients | jq -r '[.[] | "\(.class) \(.workspace.id) \(.at[0]),\(.at[1]) \(.size[0])x\(.size[1]) f\(.floating|tostring|.[0:1]) fs\(.fullscreen)"] | sort | join(" | ")'; }

# ---------------------------------------------------------------- sampling
# sampler_start NAME 'cmd' -- run cmd in a loop in the background into $GOUT/NAME.samp
sampler_start() {
    rm -f "$GOUT/$1.stop"; : > "$GOUT/$1.samp"
    ( while [ ! -e "$GOUT/$1.stop" ]; do eval "$2" >> "$GOUT/$1.samp" 2>/dev/null; sleep 0.05; done ) &
    _bg_pids="${_bg_pids:-} $!"
}
sampler_stop() { touch "$GOUT/$1.stop"; sleep 0.3; wc -l < "$GOUT/$1.samp"; }
# dup sampler line: "OK" or "DUP <ids>"
sample_ids() { if uniq_ok; then echo OK; else echo "DUP $(ids)"; fi; }

# ---------------------------------------------------------------- pixels
# shot FILE [OUTPUT] -- a settled screenshot (waits 0.6 s for motion to end first)
shot() { sleep "${SHOT_SETTLE:-0.6}"; $R shot "$1" "${2:-HEADLESS-1}" >/dev/null 2>&1; }
# pixdiff A B [THRESH] -- pixels differing by more than THRESH (default 24) in any channel,
# and the largest connected blob of them (the feedback_pixel_ab_gates rule: blobs, not bboxes)
pixdiff() {
    python3 -P - "$1" "$2" "${3:-24}" <<'PY'
import sys
from PIL import Image
import numpy as np
a = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
b = np.asarray(Image.open(sys.argv[2]).convert("RGB")).astype(int)
if a.shape != b.shape: print("SHAPE", a.shape, b.shape); sys.exit()
m = (np.abs(a - b).max(axis=2) > int(sys.argv[3]))
n = int(m.sum()); big = 0
if n:
    try:
        from scipy import ndimage
        lab, k = ndimage.label(m); big = int(np.bincount(lab.ravel())[1:].max()) if k else 0
    except ImportError:
        big = n
print(n, big)
PY
}
