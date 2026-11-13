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
#   GATE_CONTROL_SO  the build-with-the-bug for gates whose control is a build
#   GATE_OUT      a directory for this gate's small evidence files (kept on FAIL)
#   HL_NAME       the rig instance name (default g<gate tag>); always starts with g
#   RIG_SETTLE    seconds rig_start waits after the start for the load's desktop
#                 compaction to pass (default 2; see rig_start)
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
K="kitty -o cursor_blink_interval=0 -o remember_window_size=no -o initial_window_width=900 -o initial_window_height=600"
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
    # The plugin's load reloads the config, and a config reload removes the
    # empty desktops between (Rows.cpp, FullscreenDesktop::compactSoon) once
    # it has settled: 700 ms after the reload, which lands up to ~0.5 s after
    # hl.sh start returns. A gate that goes to desktop 2 before that loses its
    # empty desktop 1 -- 2 is renumbered 1 and the windows meant for 2 share 1
    # with the rest (dock_click "2: not the one on desktop 2", overview "b1/a1/a2
    # on 1/1/1", 2026-11-11). So the setup starts once that has passed.
    sleep "${RIG_SETTLE:-2}"
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
# control_build DESC -- this gate's control is a BUILD with the bug, not an option:
# a control run uses GATE_CONTROL_SO (run.sh --control-so PATH), or skips saying which build
control_build() {
    [ "$CONTROL" = 1 ] || return 0
    [ -n "${GATE_CONTROL_SO:-}" ] || skip "its control is a build: run.sh --control --control-so <$1> $(basename "$0" .sh)"
    SO=$GATE_CONTROL_SO
}
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
    $R win kitty -o cursor_blink_interval=0 -o remember_window_size=no -o initial_window_width="$w" -o initial_window_height="$h" --class "$1" >/dev/null
    wait_for 5 "[ \$(J clients | jq '[.[] | select(.class == \"$1\")] | length') -ge 1 ]" || echo "warn: $1 never mapped"
}
# kexec CLASS [W H] -- the same, launched by the compositor (hl.dsp.exec_cmd), as an app would open it
kexec() {
    local w=${2:-900} h=${3:-600}
    ev "hl.dispatch(hl.dsp.exec_cmd(\"kitty -o cursor_blink_interval=0 -o remember_window_size=no -o initial_window_width=$w -o initial_window_height=$h --class $1\"))"
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

# ---------------------------------------------------------------- hover actions
# The Super+key actions that follow the hover target (HoverActions.hpp), as the
# user binds them (Lua, as Omarchy's): Super+T float toggle, Super+P pin,
# Super+Alt+F maximize, Super+Shift+3 move to desktop 3, Super+Shift+4 the
# Omarchy way (a Lua function naming the ACTIVE window's address, as
# o.workspaces.move_window does), Super+H the plugin's minimize.
hover_binds() {
    ev 'hl.bind("SUPER + T", hl.dsp.window.float({ action = "toggle" }))'
    ev 'hl.bind("SUPER + P", hl.dsp.window.pin({ action = "toggle" }))'
    ev 'hl.bind("SUPER + ALT + F", hl.dsp.window.fullscreen({ mode = "maximized" }))'
    ev 'hl.bind("SUPER + SHIFT + 3", hl.dsp.window.move({ workspace = "3" }))'
    ev 'hl.bind("SUPER + SHIFT + 4", function() local w = hl.get_active_window(); if w then hl.dispatch(hl.dsp.window.move({ workspace = "4", follow = true, window = "address:" .. w.address })) end end)'
    ev 'hl.bind("SUPER + H", hl.plugin.hyprdrive.minimize())'
}
# hover_actions STEP HOVER NOHOVER H F -- each action with the pointer on H (HOVER H:
# a function putting it there; non-zero when it cannot) and F focused: H is acted
# on, F untouched; then with the pointer on no target (NOHOVER): F is acted on.
# The gate defines hst NAME ("<desktop> f<floating> p<pinned> fs<fullscreen>") and
# had NAME (the address); every change is put back by address before the next.
hover_actions() {
    local S=$1 HOVER=$2 NOHOVER=$3 H=$4 F=$5 HA FA h0 f0 V0
    HA=$(had "$H"); FA=$(had "$F"); h0=$(hst "$H"); f0=$(hst "$F"); V0=$(shown)
    local HW=${h0%% *} FW=${f0%% *}
    local open=1; [ -n "${HOVER_OPEN:-}" ] || open=0
    on() { focus "$FA"; sleep 0.3; $HOVER "$1" || echo "warn: cannot hover $1"; }
    back() {  # every state of H and F as it was, by address, and the view
        local a w
        for a in "$HA:$HW" "$FA:$FW"; do
            w=${a#*:}; a=${a%%:*}
            ev "hl.dispatch(hl.dsp.window.fullscreen({ window = [[address:$a]], mode = \"maximized\", action = \"unset\" }))"
            [ "$(J clients | jq -r ".[] | select(.address == \"$a\") | .pinned")" = true ] && ev "hl.dispatch(hl.dsp.window.pin({ window = [[address:$a]], action = \"toggle\" }))"
            ev "hl.dispatch(hl.dsp.window.float({ window = [[address:$a]], action = \"disable\" }))"
            [ "$(J clients | jq -r ".[] | select(.address == \"$a\") | .workspace.id")" = "$w" ] || ev "hl.dispatch(hl.dsp.window.move({ window = [[address:$a]], workspace = \"$w\", follow = false }))"
        done
        go "$V0"; focus "$FA"; settle 3 geom
    }
    ovw() { [ "$open" = 0 ] || dbg gesture state | grep -q ' 1 overview' && echo 1; }
    # Super+T: floats, and back
    on "$H"; $R tap Super+T >/dev/null; sleep 1
    check "$S T: Super+T over $H ($F focused): $H floats" "$(is "$(hst "$H" | cut -d' ' -f2)" f1)" "$H $(hst "$H")"
    check "$S T: ... $F untouched${HOVER_OPEN:+, the overview open, $H still a tile}" "$(is "$(hst "$F")$(ovw)$([ "$open" = 0 ] || $HOVER "$H" && echo 1)" "${f0}11")" "$F $(hst "$F") overview $(ovw)"
    $HOVER "$H"; $R tap Super+T >/dev/null; sleep 1
    check "$S T: Super+T over it again: tiled" "$(is "$(hst "$H" | cut -d' ' -f2)" f0)" "$H $(hst "$H")"
    back
    # Super+P: pins a floating H (Hyprland pins floating windows only)
    ev "hl.dispatch(hl.dsp.window.float({ window = [[address:$HA]], action = \"enable\" }))"; settle 3 geom
    on "$H"; $R tap Super+P >/dev/null; sleep 0.8
    check "$S P: Super+P over the floating $H: pinned, $F not" "$(is "$(hst "$H" | cut -d' ' -f3) $(hst "$F" | cut -d' ' -f3)" "p1 p0")" "$H $(hst "$H"), $F $(hst "$F")"
    back
    # Super+Alt+F: maximized, and back
    on "$H"; $R tap Super+Alt+F >/dev/null; sleep 1
    check "$S M: Super+Alt+F over $H: maximized, $F untouched" "$(is "$(hst "$H" | cut -d' ' -f4) $(hst "$F")" "fs1 $f0")" "$H $(hst "$H"), $F $(hst "$F")"
    $HOVER "$H"; $R tap Super+Alt+F >/dev/null; sleep 1
    check "$S M: Super+Alt+F over it again: not maximized" "$(is "$(hst "$H" | cut -d' ' -f4)" fs0)" "$H $(hst "$H")"
    back
    # Super+Shift+3: H to 3, silently (F keeps the focus, the view stays)
    on "$H"; local V1 TB; V1=$(shown); TB=$([ "$open" = 0 ] || tile_of "$H"); $R tap Super+Shift+3 >/dev/null; sleep 1
    check "$S N: Super+Shift+3 over $H: $H on 3, $F on $FW and focused, still looking at $V1" "$(is "$(hst "$H" | cut -d' ' -f1) $(hst "$F" | cut -d' ' -f1) $(J activewindow | jq -r .address) $(shown)" "3 $FW $FA $V1")" "$H $(hst "$H"), $F $(hst "$F"), focus $(J activewindow | jq -r .address), shown $(shown)"
    [ "$open" = 0 ] || check "$S N: ... the overview open, relaid out: $H's tile is not where it was" "$(is "$(ovw)$([ "$(tile_of "$H")" != "$TB" ] && echo 1)" 11)" "overview $(ovw), $H's tile $TB -> $(tile_of "$H")"
    back
    # Super+Shift+4 the Omarchy way (the bind names the active window): the same
    on "$H"; $R tap Super+Shift+4 >/dev/null; sleep 1
    check "$S O: Omarchy's move (active window by address) over $H: $H on 4, $F on $FW" "$(is "$(hst "$H" | cut -d' ' -f1) $(hst "$F" | cut -d' ' -f1)" "4 $FW")" "$H $(hst "$H"), $F $(hst "$F")"
    back
    # Super+H: H minimized, F untouched
    on "$H"; $R tap Super+H >/dev/null; sleep 1.2
    check "$S H: Super+H over $H: minimized, $F untouched" "$(is "$([ "$(hst "$H" | cut -d' ' -f1)" -lt 0 ] && echo min) $(hst "$F")" "min $f0")" "$H $(hst "$H"), $F $(hst "$F")"
    hq dispatch 'hl.plugin.hyprdrive.minimize("restore")' >/dev/null 2>&1; wait_for 3 "[ \"\$(hst $H | cut -d' ' -f1)\" = $HW ]"; sleep 0.6
    back
    # no target: the focused window, every action
    on "$F" >/dev/null 2>&1; $NOHOVER; sleep 0.3
    $R tap Super+T >/dev/null; sleep 1
    check "$S 0: Super+T over no target: $F floats, $H untouched" "$(is "$(hst "$F" | cut -d' ' -f2) $(hst "$H")" "f1 $h0")" "$F $(hst "$F"), $H $(hst "$H")"
    $R tap Super+P >/dev/null; sleep 0.8
    check "$S 0: Super+P over no target: $F pinned" "$(is "$(hst "$F" | cut -d' ' -f3)" p1)" "$F $(hst "$F")"
    back; focus "$FA"; $NOHOVER; sleep 0.3
    $R tap Super+Alt+F >/dev/null; sleep 1
    check "$S 0: Super+Alt+F over no target: $F maximized, $H untouched" "$(is "$(hst "$F" | cut -d' ' -f4) $(hst "$H")" "fs1 $h0")" "$F $(hst "$F"), $H $(hst "$H")"
    back; focus "$FA"; $NOHOVER; sleep 0.3
    $R tap Super+H >/dev/null; sleep 1.2
    check "$S 0: Super+H over no target: $F minimized" "$([ "$(hst "$F" | cut -d' ' -f1)" -lt 0 ] 2>/dev/null && echo 1)" "$F $(hst "$F")"
    hq dispatch 'hl.plugin.hyprdrive.minimize("restore")' >/dev/null 2>&1; wait_for 3 "[ \"\$(hst $F | cut -d' ' -f1)\" = $FW ]"; sleep 0.6
    back; focus "$FA"; $NOHOVER; sleep 0.3
    $R tap Super+Shift+3 >/dev/null; sleep 1
    check "$S 0: Super+Shift+3 over no target: $F on 3, $H untouched" "$(is "$(hst "$F" | cut -d' ' -f1) $(hst "$H")" "3 $h0")" "$F $(hst "$F"), $H $(hst "$H")"
    back
}
