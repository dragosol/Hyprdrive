#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/lib/rig.sh -- THE shared library for promoted gates. Runs IN THE GUEST.
#
# Every mechanism in here is distilled from a rig that already caught (or was
# burned by) the failure the mechanism guards against; provenance is marked
# [file:line] throughout. Do not "improve" a mechanism without re-reading its
# source rig -- most of these encode a measured failure, not a preference.
#
# Contract:
#   - Sourcing this file defines functions and constants ONLY. Nothing moves.
#   - rig_env discovers the session; every helper lazily calls it, so outside
#     the guest every helper degrades to a clear stderr message + return 1.
#   - Plain helpers `return 1` on failure (callers add `|| exit 1`).
#     *_or_die helpers exit 1 -- they gate whether anything after them means
#     anything at all (liveness, pointer placement, capture pipeline).
#   - headless_on installs `trap headless_off EXIT` [x47_rig.sh:37-60]. A gate
#     needing more cleanup must call headless_on FIRST, then CHAIN its own:
#         trap 'my_cleanup; headless_off; hyprwall_resume' EXIT
#
# Typical gate skeleton:
#   source "$(dirname "$0")/lib/rig.sh"
#   rig_env        || exit 1
#   hyprwall_pause
#   headless_on    || exit 1
#   fixture_kitty GATEFIX 600 300 800 500
#   ...measure...  alive_or_die "after the click"
#   headless_off; hyprwall_resume     # the EXIT trap also covers aborts

# ---------------------------------------------------------------- constants --
# Source-time computation only (allowed side effect: env/vars).
RIG_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RIG_CELL_PY=${RIG_CELL_PY:-$RIG_LIB_DIR/../x24_cell.py}    # dock cell predictor [x24_cell.py:1-9]
# Headless output mode. The dock geometry the cell predictor computes and the
# ydotool half-space rule are both functions of THIS mode, so the headless
# output must come up at the guest's own 2560x1600, never its default
# [x47_rig.sh:88-92]. (x47_rig.sh:94 proved the swap at @60; suite standard
# is @120 -- override RIG_HEADLESS_MODE before headless_on if a build rejects it.)
RIG_HEADLESS_MODE=${RIG_HEADLESS_MODE:-2560x1600@120}

# ydotool keycodes [g1_rig.sh:36, x24_dock_click.sh:28]
K_ESC=1; K_BKSP=14; K_TAB=15; K_K=37; K_SHIFT=42; K_X=45; K_SPACE=57; K_F5=63

# ---------------------------------------------------------------- discovery --
# NEVER hardcode wayland-1: a restarted GDM leaves the old, wedged Hyprland
# holding that socket while the live session moves on, and clients then connect
# to the corpse and map nothing, silently [g1_rig.sh:23-26].
rig_env() {
    export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}   # [crash_repro.sh:18]
    if [ ! -d "$XDG_RUNTIME_DIR" ]; then
        echo "rig: $XDG_RUNTIME_DIR does not exist -- this library runs IN THE GUEST (hyprvm, ssh -p 2222), not on the host" >&2
        return 1
    fi
    WAYLAND_DISPLAY=$(cd "$XDG_RUNTIME_DIR" && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)   # [g1_rig.sh:26]
    if [ -z "$WAYLAND_DISPLAY" ]; then
        echo "rig: no wayland socket under $XDG_RUNTIME_DIR -- not a live guest session" >&2
        return 1
    fi
    export WAYLAND_DISPLAY
    export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus          # [g1_rig.sh:27]
    export YDOTOOL_SOCKET=$XDG_RUNTIME_DIR/.ydotool_socket                  # [g1_rig.sh:28]
    HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -1)   # [g1_rig.sh:29]
    if [ -z "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
        echo "rig: no Hyprland instance under $XDG_RUNTIME_DIR/hypr -- compositor is not running here" >&2
        return 1
    fi
    export HYPRLAND_INSTANCE_SIGNATURE
    RIG_SIG0=$HYPRLAND_INSTANCE_SIGNATURE     # liveness baseline [crash_repro.sh:20-22]
    RIG_ENV_OK=1
}

_rig_need() {
    [ "${RIG_ENV_OK:-0}" = 1 ] && return 0
    rig_env
}

# ----------------------------------------------------------------- liveness --
rig_sig() { ls -t "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -1; }          # [crash_repro.sh:19]

# Compositor liveness via signature re-read: a crash + gdm-autologin restart
# mints a NEW instance dir, so a changed signature means the compositor under
# test died since rig_env ran [crash_repro.sh:22-32]. Call between phases with
# a label naming the phase, crash_repro style ("DIED: during open").
alive_or_die() { # alive_or_die [LABEL]
    _rig_need || return 1
    local now; now=$(rig_sig)
    if [ "$now" != "${RIG_SIG0:-}" ]; then
        echo "DIED: ${1:-compositor signature changed} (${RIG_SIG0:-?} -> ${now:-gone})" >&2
        exit 1
    fi
}

# ------------------------------------------------------------- hyprctl(Lua) --
# 0.56 hyprctl parses args as Lua; `hyprctl keyword` is DEAD -- every call
# answers "can't work with non-legacy parsers" and returns 0, so a rig that
# used it configured nothing and said nothing [x47_rig.sh:104-107]. Everything
# goes through hl.dispatch / hl.config, and config is READ BACK (opt_want).
hl()       { _rig_need || return 1; hyprctl eval "$1"; }                     # raw eval, output kept (readbacks, multi-line Lua)
dsp()      { _rig_need || return 1; hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }   # [x47_rig.sh:30]
ov()       { dsp "hl.plugin.scrolloverview.overview([[$1]])"; }              # [x47_rig.sh:31]
cfg_dock() { _rig_need || return 1; hyprctl eval "hl.config({plugin={scrolloverview={dock={$1}}}}) return 0" >/dev/null 2>&1; }   # [z_rig.sh:14]
cfg_ov()   { _rig_need || return 1; hyprctl eval "hl.config({plugin={scrolloverview={$1}}}) return 0" >/dev/null 2>&1; }          # [z_rig.sh:15]

# Read a config value back to prove it landed [x47_rig.sh:108-111], full option
# path (e.g. plugin:scrolloverview:dock:autohide). NOT safe inside `| while
# read` (subshell swallows the failure) and NOT after `IFS=,` (the inner
# `read -r` inherits it and stops splitting) [x47_rig.sh:132-137].
opt_want() { # opt_want OPTION EXPECTED
    _rig_need || return 1
    local VAL SET
    read -r VAL SET <<< "$(hyprctl getoption "$1" | head -2 | awk '{print $2}' | tr '\n' ' ')"
    [ "$VAL" = "$2" ] || { echo "rig: $1 is $VAL, wanted $2" >&2; return 1; }
}

# -------------------------------------------------------------------- input --
# ydotool's absolute space is HALF this guest's 2560x1600 output, whichever
# output is enabled [x47_rig.sh:32-33, 88-92]. All coordinates below are
# MONITOR pixels; the halving happens here and nowhere else.
warp() { _rig_need || return 1; ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; }

# Warp and VERIFY the pointer landed: every silent failure this project has
# recorded around input started with a warp that did not land where the rig
# aimed it [x47_rig.sh:220-226].
warp_or_die() { # warp_or_die X Y
    _rig_need || return 1
    local ax=$1 ay=$2 CX CY
    warp "$ax" "$ay"
    sleep 0.4
    read -r CX CY <<< "$(hyprctl cursorpos | tr -d ',')"
    if [ "$(( CX > ax - 6 && CX < ax + 6 && CY > ay - 6 && CY < ay + 6 ))" != 1 ]; then
        echo "rig: warp landed at ${CX:-?},${CY:-?}, not $ax,$ay" >&2
        exit 1
    fi
}

# Held press (~120ms) with sub-threshold jitter: a press+release in the same
# instant does not exercise the real path [x24_dock_click.sh:10-11,29-31].
# NO tail sleep -- callers own their waits; a tail once pushed a mid-flight
# sample past the behaviour it was sampling [z_rig.sh:31-33].
click() { # click X Y
    _rig_need || return 1
    local x=$1 y=$2 d
    warp "$x" "$y"; sleep 0.5
    ydotool click 0x40                                     # press, no release
    for d in 2 -2 3 -1 0; do warp $((x+d)) $((y-d)); sleep 0.025; done
    ydotool click 0x80                                     # release
}

key()      { _rig_need || return 1; ydotool key "$1:1" "$1:0"; sleep 0.30; }   # [g1_rig.sh:34]
key_down() { _rig_need || return 1; ydotool key "$1:1"; }                      # [x24_dock_click.sh:28]
key_up()   { _rig_need || return 1; ydotool key "$1:0"; }                      # [x24_dock_click.sh:32]

# ----------------------------------------------------------------- fixtures --
# kitty, NEVER foot (standing rule): foot has no per-window opaque switch and a
# translucent fixture makes every pixel count ambiguous [g1_rig.sh:63-64].
# Opaque by default; geometry is ALWAYS set explicitly via Lua IPC because all
# windows float and sizes leak between rigs [z_rig.sh:34-45 + input-rig memory].
# Places EVERY window of CLASS (z_rig semantics); spawn one class per window.
fixture_kitty() { # fixture_kitty CLASS X Y W H [COLOUR] [CMD]
    _rig_need || return 1
    local cls=${1:?class} fx=${2:?x} fy=${3:?y} fw=${4:?w} fh=${5:?h}
    local colour=${6:-#101820} cmd=${7:-sleep 3600}
    setsid kitty -c NONE --class "$cls" -o background="$colour" -o background_opacity=1.0 \
        -o confirm_os_window_close=0 --hold sh -c "$cmd" >/dev/null 2>&1 </dev/null &   # [g1_rig.sh:68-69, x47_rig.sh:150]
    sleep 2.2
    hyprctl clients -j | grep -q "\"$cls\"" || { echo "rig: fixture $cls did not appear" >&2; return 1; }   # [g1_rig.sh:71]
    hyprctl eval "$(cat <<LUA
for _, w in ipairs(hl.get_windows()) do
    if w.class == "$cls" then
        hl.dispatch(hl.dsp.focus({window = w}))
        hl.dispatch(hl.dsp.window.resize({x = $fw, y = $fh, relative = false}))
        hl.dispatch(hl.dsp.window.move({x = $fx, y = $fy, relative = false}))
    end
end
return 1
LUA
)" >/dev/null 2>&1                                                            # [z_rig.sh:35-45]
    sleep 0.8
}

# Kill every window-owning pid except KEEPCLASS. The cell locator predicts from
# RUNNING classes, so every other mapped window shifts every icon centre and a
# click lands on the wrong app -- measured: z7's first run focused Nautilus
# [z_rig.sh:53-59]. -9, and run it immediately before every click (see
# dock_click): Nautilus gets D-Bus-activated back to life between a single
# startup sweep and the click [z_rig.sh:20-23].
killothers() { # killothers KEEPCLASS
    _rig_need || return 1
    hyprctl clients -j | python3 -c "
import json,sys
keep=sys.argv[1]
for c in json.load(sys.stdin):
    if c.get('class') not in (keep,'') and c.get('pid',0)>0: print(c['pid'])" "$1" \
        | xargs -r kill -9 2>/dev/null                                        # [z_rig.sh:17-19]
    return 0
}

# --------------------------------------------------------------- dock cells --
# Icon centres are PREDICTED from Dock.cpp's own constants, never read back
# from the plugin: a rig that asked the plugin where to click could never catch
# a layout bug [x24_dock_click.sh:4-8, x24_cell.py:5-8].
dock_cell() { # dock_cell <class|gutter>  ->  "X Y" in monitor pixels
    _rig_need || return 1
    [ -f "$RIG_CELL_PY" ] || { echo "rig: cell predictor $RIG_CELL_PY missing" >&2; return 1; }
    hyprctl clients -j | python3 "$RIG_CELL_PY" "$1"
}

dock_click() { # dock_click CLASS [shift] -- sweep, predict, held click
    _rig_need || return 1
    local cls=${1:?class} mode=${2:-noshift} cx cy d
    killothers "$cls"; sleep 0.6                           # sweep before EVERY click [z_rig.sh:20-23]
    read -r cx cy <<< "$(dock_cell "$cls")"
    [ -n "${cx:-}" ] || { echo "rig: no dock cell predicted for $cls" >&2; return 1; }
    warp_or_die "$cx" "$cy"
    sleep 0.5
    if [ "$mode" = shift ]; then ydotool key 42:1; sleep 0.1; fi              # [x24_dock_click.sh:28]
    ydotool click 0x40
    for d in 2 -2 3 -1 0; do warp $((cx+d)) $((cy-d)); sleep 0.025; done      # [x24_dock_click.sh:29-31]
    ydotool click 0x80
    if [ "$mode" = shift ]; then ydotool key 42:0; fi                         # [x24_dock_click.sh:32]
    return 0                                               # no tail sleep: callers own their waits [z_rig.sh:31-33]
}

# ----------------------------------------------------------------- hyprwall --
# A wallpaper change moves every pixel in the frame, so every before/after diff
# gate would pass trivially -- the exact failure the gates exist to prevent
# [x1_fixture.sh:25-28]. Dead-man resume via systemd-run so it comes back even
# if the run dies where no trap fires (SIGKILL, compositor down under it)
# [x47_rig.sh:62-65]; NAMED unit so repeated pauses replace the pending resume
# instead of stacking [x1_fixture.sh:30-32].
hyprwall_pause() { # hyprwall_pause [DURATION=30min]
    _rig_need || return 1
    systemctl --user stop hyprwall.timer 2>/dev/null
    systemctl --user stop hyprwall-resume.timer 2>/dev/null
    systemd-run --user --on-active="${1:-30min}" --unit=hyprwall-resume \
        systemctl --user start hyprwall.timer >/dev/null 2>&1
    return 0
}

hyprwall_resume() { # [x1_stress.sh:326-327]
    _rig_need || return 1
    systemctl --user stop hyprwall-resume.timer 2>/dev/null
    systemctl --user start hyprwall.timer 2>/dev/null
    return 0
}

# ----------------------------------------------------------------- headless --
# Virtual-1 draws ~1fps while no viewer is attached to the VM, so grim hands
# back the same stale frame over and over -- a counter ticking every 80ms once
# scored 0 changed pixels between two frames [x47_rig.sh:70-74]. Pixel gates
# run on ONE headless output with Virtual-1 disabled: a starved Virtual-1
# stalls every output including headless [g1_rig.sh:45-46].
headless_on() {
    _rig_need || return 1
    hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = false})" >/dev/null 2>&1; sleep 1.2   # [x47_rig.sh:75]
    # `hyprctl output create headless` is NOT idempotent: four calls once made
    # HEADLESS-1..4 and scattered the fixture across all of them
    # [x1_fixture.sh:39-44]. Tear down, then build exactly one.
    local m HL
    for m in $(hyprctl monitors all -j | python3 -c "
import json,sys
print(' '.join(m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')))"); do
        hyprctl output remove "$m" >/dev/null 2>&1; sleep 0.4
    done                                                                      # [x47_rig.sh:76-80]
    sleep 1
    hyprctl output create headless >/dev/null 2>&1; sleep 1.5
    HL=$(hyprctl monitors all -j | python3 -c "
import json,sys
hs=[m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')]
print(hs[0] if len(hs)==1 else '')")
    [ -n "$HL" ] || { echo "rig: expected exactly one headless output" >&2; return 1; }   # [x47_rig.sh:82-87]
    # The swap-back must be un-skippable: an aborted run once left the guest on
    # a headless output with Virtual-1 disabled and a blank actual screen
    # [x47_rig.sh:37-42]. Flag + trap BEFORE the risky steps; chain your own
    # cleanup AFTER this call (see header).
    RIG_HEADLESS=1
    trap headless_off EXIT
    # Same MODE as Virtual-1, through hl.monitor (keyword parser is dead on
    # 0.56) [x47_rig.sh:88-94].
    hyprctl eval "return hl.monitor({output = [[$HL]], mode = [[$RIG_HEADLESS_MODE]], position = [[0x0]], scale = 1})" >/dev/null 2>&1; sleep 1.2
    hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = true})" >/dev/null 2>&1; sleep 1.5    # [x47_rig.sh:95]
    read -r RIG_MON RIG_W RIG_H <<< "$(hyprctl monitors -j | python3 -c "
import json,sys
m=json.load(sys.stdin)[0]; print(m['name'], m['width'], m['height'])")"       # [x47_rig.sh:97-99]
    local want_w=${RIG_HEADLESS_MODE%%x*} rest=${RIG_HEADLESS_MODE#*x}
    local want_h=${rest%%@*}
    case "$RIG_MON" in HEADLESS*) ;; *)
        echo "rig: expected the headless output, got $RIG_MON" >&2; headless_off; return 1 ;; esac
    if [ "$RIG_W" != "$want_w" ] || [ "$RIG_H" != "$want_h" ]; then
        echo "rig: headless came up ${RIG_W}x${RIG_H}, not ${want_w}x${want_h}" >&2
        headless_off; return 1
    fi                                                                        # [x47_rig.sh:100-102]
    export RIG_MON RIG_W RIG_H
}

headless_off() {
    [ "${RIG_HEADLESS:-0}" = 1 ] || return 0               # idempotent: safe from trap AND explicit call
    _rig_need || return 1
    RIG_HEADLESS=0
    # Virtual-1 comes back FIRST: removing the last output while it is the only
    # enabled one leaves the session with nowhere to put its windows
    # [x47_rig.sh:49-52].
    hyprctl eval "return hl.monitor({output = [[Virtual-1]], disabled = false})" >/dev/null 2>&1
    sleep 1.2
    local m
    for m in $(hyprctl monitors all -j | python3 -c "
import json,sys
print(' '.join(m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')))"); do
        hyprctl output remove "$m" >/dev/null 2>&1; sleep 0.4
    done                                                                      # [x47_rig.sh:53-57]
    return 0
}

# ------------------------------------------------------------ capture guard --
# Two full-screen grabs 0.5s apart MUST differ -- a frozen output hands back
# the same frame forever, and then every "nothing changed" a gate reports means
# nothing [g1_rig.sh:19-20, x47_rig.sh:208-215]. Requires something on screen
# that changes on its own (x47's counter fixture ticks every 80ms). Frames are
# left on disk for the host-side gate; identical frames = explicit FAIL.
pipeline_live_or_die() { # pipeline_live_or_die OUTDIR TAG
    _rig_need || return 1
    local out=${1:?outdir} tag=${2:?tag}
    mkdir -p "$out"      # a missing dir makes grim skip writes SILENTLY [crash_repro.sh:17]
    grim "$out/$tag-p0.png" 2>/dev/null
    sleep 0.5
    grim "$out/$tag-p1.png" 2>/dev/null
    if [ ! -s "$out/$tag-p0.png" ] || [ ! -s "$out/$tag-p1.png" ]; then
        echo "DIED: grim wrote nothing to $out -- capture pipeline is down" >&2
        exit 1
    fi
    if cmp -s "$out/$tag-p0.png" "$out/$tag-p1.png"; then
        echo "DIED: capture pipeline is stale -- $tag-p0/$tag-p1 are byte-identical" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------- anim rate --
# Global slowdown so even this guest's poor capture rate gets a dozen frames of
# a 400ms flight [slowmo.sh:2-4]. Read back to prove it landed [slowmo.sh:15].
# Do NOT arm this for input-TIMING gates: flights then outlive the wall-clock
# click spacing and the gate tests nothing [z_rig.sh:148-151].
anim_slow() { # anim_slow FACTOR
    _rig_need || return 1
    hyprctl eval "hl.config({plugin={scrolloverview={anim_scale=$1}}}) return 0" >/dev/null 2>&1   # [z_rig.sh:15, slowmo.sh:13]
    sleep 0.6
    local rb
    rb=$(hyprctl getoption plugin:scrolloverview:anim_scale | head -1 | awk '{print $2}')
    awk -v a="${rb:-x}" -v b="$1" 'BEGIN{exit (a+0==b+0)?0:1}' \
        || { echo "rig: anim_scale readback '$rb', wanted $1" >&2; return 1; }
    RIG_ANIM_SLOWED=1
}

anim_restore() {
    _rig_need || return 1
    hyprctl eval "hl.config({plugin={scrolloverview={anim_scale=1}}}) return 0" >/dev/null 2>&1    # [slowmo.sh:30, z_rig.sh:104]
    RIG_ANIM_SLOWED=0
    return 0
}
