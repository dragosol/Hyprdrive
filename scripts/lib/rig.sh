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

# THE plugin identity. One constant; everything the gates say about the plugin
# -- its name in `hyprctl plugin list`, its Lua namespace, its config-key
# prefix, its .so, its favorites store -- is DERIVED from it. Before this,
# sixty-odd literals across twenty gates each spelled the name out, which made
# the Phase-9 rename a rename of the harness as much as of the plugin, and a
# harness edited in the same commit as the thing it measures proves nothing.
# Override for a one-off run against a differently-named build: RIG_NS=... gate.
RIG_NS=${RIG_NS:-hyprdrive}
RIG_KEY=plugin:$RIG_NS                                          # config-key prefix
RIG_SO=$RIG_NS.so                                               # built artifact
RIG_FAV=${XDG_STATE_HOME:-$HOME/.local/state}/$RIG_NS/favorites # dock favorites store
export RIG_NS RIG_KEY RIG_SO RIG_FAV
RIG_CELL_PY=${RIG_CELL_PY:-$RIG_LIB_DIR/../x24_cell.py}    # dock cell predictor [x24_cell.py:1-9]
# Headless output mode. The dock geometry the cell predictor computes and the
# ydotool half-space rule are both functions of THIS mode, so the headless
# output must come up at the guest's own 2560x1600, never its default
# [x47_rig.sh:88-92]. (x47_rig.sh:94 proved the swap at @60; suite standard
# is @120 -- override RIG_HEADLESS_MODE before headless_on if a build rejects it.)
RIG_HEADLESS_MODE=${RIG_HEADLESS_MODE:-2560x1600@120}

# The guest's real output and the mode its config pins it to. gate_slate puts
# Virtual-1 back to exactly this before every gate: the ydotool mapping below is
# a function of it, and a session that came up before the rule applied sits at
# the virtio-gpu preferred 1280x800 instead [measured 2026-08-11, zrig/gatefire].
RIG_MON_NAME=${RIG_MON_NAME:-Virtual-1}
RIG_MON_MODE=${RIG_MON_MODE:-2560x1600@120}

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
ov()       { dsp "hl.plugin.$RIG_NS.overview([[$1]])"; }              # [x47_rig.sh:31]
cfg_dock() { _rig_need || return 1; hyprctl eval "hl.config({plugin={$RIG_NS={dock={$1}}}}) return 0" >/dev/null 2>&1; }   # [z_rig.sh:14]
cfg_ov()   { _rig_need || return 1; hyprctl eval "hl.config({plugin={$RIG_NS={$1}}}) return 0" >/dev/null 2>&1; }          # [z_rig.sh:15]

# `ov off` and WAIT for the close animation to actually finish.
#
# This is not politeness, it is the single most expensive lesson in this file.
# An overview holds its monitor as a WEAK ref (IOverview::pMonitor) and close()
# dereferences it (scrollOverview.cpp:5052). Remove the output while an overview
# is still on it and the object survives pointing at freed memory; the next
# `overview off` -- which is the first line of the NEXT gate's fixture -- takes
# the whole compositor down with SIGSEGV inside CScrollOverview::close().
#
# Measured 2026-08-11 and reproduced on EVERY build from 1769513 (untouched
# parent) to 0b6782f: g1's run phase ends without closing, g1's EXIT trap runs
# headless_off which removes the output under it, and g5's first `ov off` kills
# Hyprland. gdm restarts it in ~2s, so nothing in the old suite noticed: the
# remaining 22 gates simply ran against a DIFFERENT compositor, with no plugin
# fixtures, hyprwall re-armed, and the pointer re-bound to a 1280x800 output.
# That is the whole of "25/27 gates fail and the numbers move every run".
#
# The wait scales with anim_scale because a slowmo'd rig's close takes that much
# longer, and a headless_off that returns mid-animation is the same landmine.
ov_off_settled() {
    _rig_need || return 1
    local s w
    s=$(hyprctl getoption $RIG_KEY:anim_scale 2>/dev/null | head -1 | awk '{print $2+0}')
    ov off
    w=$(awk -v s="${s:-1}" 'BEGIN{ if (s<1) s=1; w=0.9*s; if (w>8) w=8; printf "%.2f", w }')
    sleep "$w"
    return 0
}

# Read a config value back to prove it landed [x47_rig.sh:108-111], full option
# path -- build it from the identity constant, e.g. "$RIG_KEY:dock:autohide".
# NOT safe inside `| while
# read` (subshell swallows the failure) and NOT after `IFS=,` (the inner
# `read -r` inherits it and stops splitting) [x47_rig.sh:132-137].
opt_want() { # opt_want OPTION EXPECTED
    _rig_need || return 1
    local VAL SET
    read -r VAL SET <<< "$(hyprctl getoption "$1" | head -2 | awk '{print $2}' | tr '\n' ' ')"
    [ "$VAL" = "$2" ] || { echo "rig: $1 is $VAL, wanted $2" >&2; return 1; }
}

# -------------------------------------------------------------------- input --
# ydotool's absolute space is a FIXED 1280x800 grid that Hyprland stretches over
# the output its virtual pointer is BOUND to -- not over the layout, and not over
# whichever output happens to be enabled: measured 2026-08-11, the same
# ydotool(640,400) lands at 1281,801 with a 2560x1600 Virtual-1, with a 1920x1080
# headless alone, and with a 4480x1600 two-output layout. So on this guest a
# monitor pixel is TWO ydotool units [x47_rig.sh:32-33, 88-92].
#
# "On this guest" is the trap, and it is not hypothetical. The binding is made
# when the device appears, so a compositor that restarts under the suite comes
# back with the pointer bound to Virtual-1 at its virtio-gpu preferred 1280x800
# and the factor is ONE. That is what a whole suite run looked like on
# 2026-08-11: y11 aimed at 1245,1555, landed at 622,777 -- exactly half -- and
# every gate that clicks or hovers failed with it (zrig/gatefire/).
#
# So the factor is MEASURED, once per process, instead of assumed. All
# coordinates below are MONITOR pixels; the conversion happens here and nowhere
# else.
RIG_PTR_DIV=${RIG_PTR_DIV:-}

# Two probe warps and one division. The probe points are deliberately small
# (<=500,350 ydotool units = <=1000,700 monitor px at the expected factor) so
# neither one can land off the edge of the narrowest output this rig ever sees
# and be CLAMPED -- a clamped sample reads back as a smaller factor and would
# calibrate the rig into aiming short of every target.
rig_calibrate() {
    _rig_need || return 1
    local ax ay bx by div
    ydotool mousemove -a -x 100 -y 100 2>/dev/null; sleep 0.35
    read -r ax ay <<< "$(hyprctl cursorpos 2>/dev/null | tr -d ',')"
    ydotool mousemove -a -x 500 -y 350 2>/dev/null; sleep 0.35
    read -r bx by <<< "$(hyprctl cursorpos 2>/dev/null | tr -d ',')"
    div=$(awk -v ax="${ax:-0}" -v bx="${bx:-0}" -v ay="${ay:-0}" -v by="${by:-0}" 'BEGIN{
        dx=(bx-ax)/400; dy=(by-ay)/250;
        if (dx < 0.4 || dx > 8) exit 1;
        if (dy > 0 && (dy/dx < 0.9 || dy/dx > 1.1)) exit 1;   # x and y must agree
        printf "%.4f", dx }')
    if [ -z "$div" ]; then
        echo "rig: could not calibrate the pointer (${ax:-?},${ay:-?} -> ${bx:-?},${by:-?}) -- is ydotoold running?" >&2
        return 1
    fi
    RIG_PTR_DIV=$div
    export RIG_PTR_DIV
}

warp() { # warp X Y -- MONITOR pixels
    _rig_need || return 1
    [ -n "$RIG_PTR_DIV" ] || rig_calibrate || return 1
    local wx wy
    read -r wx wy <<< "$(awk -v x="$1" -v y="$2" -v d="$RIG_PTR_DIV" 'BEGIN{printf "%d %d", int(x/d+0.5), int(y/d+0.5)}')"
    ydotool mousemove -a -x "$wx" -y "$wy" 2>/dev/null
}

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
    # Under a suite the hold belongs to the suite, and a gate's own pause must
    # not re-arm the dead-man: the unit is named, so the LAST caller wins, and
    # x1_fixture.sh's bare 30-minute pause was silently replacing the suite's
    # 180-minute one. Measured 2026-08-12 -- the short dead-man fired 34 minutes
    # into a 45-minute run, started an OnUnitActiveSec=3min rotation, and moved
    # the wallpaper four times under gates that measure it (x64's frost half and
    # z3's colour locator both went red on the photograph rather than the build).
    # Same guard hyprwall_resume has, for the same reason.
    [ "${RIG_HYPRWALL_HELD:-0}" = 1 ] && return 0
    systemctl --user stop hyprwall-resume.timer 2>/dev/null
    systemd-run --user --on-active="${1:-30min}" --unit=hyprwall-resume \
        systemctl --user start hyprwall.timer >/dev/null 2>&1
    return 0
}

hyprwall_resume() { # [x1_stress.sh:326-327]
    _rig_need || return 1
    # A suite run owns the timer for its WHOLE length. Every gate ships its own
    # pause/resume pair, so gate N's resume re-armed the rotation for gate N+1's
    # setup -- and OnActiveSec=3min means starting the timer is itself a
    # rotation trigger. suite.sh exports this and drops it exactly once, at the
    # end.
    [ "${RIG_HYPRWALL_HELD:-0}" = 1 ] && return 0
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
    ov_off_settled          # never move outputs under a live overview (see ov_off_settled)
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
    # The overview goes FIRST, before any output moves. Most rigs that leave one
    # open leave it open on the headless output this is about to delete, and
    # that is a compositor-killer -- see ov_off_settled for the whole story. It
    # belongs here rather than in each rig because the trap path is exactly the
    # one a rig aborting halfway cannot cover for itself.
    ov_off_settled
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
    hyprctl eval "hl.config({plugin={$RIG_NS={anim_scale=$1}}}) return 0" >/dev/null 2>&1   # [z_rig.sh:15, slowmo.sh:13]
    sleep 0.6
    local rb
    rb=$(hyprctl getoption $RIG_KEY:anim_scale | head -1 | awk '{print $2}')
    awk -v a="${rb:-x}" -v b="$1" 'BEGIN{exit (a+0==b+0)?0:1}' \
        || { echo "rig: anim_scale readback '$rb', wanted $1" >&2; return 1; }
    RIG_ANIM_SLOWED=1
}

anim_restore() {
    _rig_need || return 1
    hyprctl eval "hl.config({plugin={$RIG_NS={anim_scale=1}}}) return 0" >/dev/null 2>&1    # [slowmo.sh:30, z_rig.sh:104]
    RIG_ANIM_SLOWED=0
    return 0
}

# --------------------------------------------------------------- clean slate --
# One gate must not be allowed to decide the next gate's verdict.
#
# Every item below is residue this suite has been CAUGHT measuring, not a
# precaution: g1's three fixtures still mapped while g5 counted result cards;
# x26's dock:autohide=false still set when x30 measured the autohide; a
# HEADLESS output left behind by an aborted rig so the next `output create`
# made a second one; the login-keyring prompt parked 575x154 in the middle of
# every frame from session start; and Virtual-1 sitting at the virtio-gpu
# preferred 1280x800 after a restart, which silently halves every click.
#
# suite.sh calls this between gates. A gate run on its own does not need it --
# but it is safe to call, and a gate that is being debugged after a messy run
# usually wants it.

# Wait for a session to exist and the plugin to be in it. Used after a
# compositor death: gdm's autologin brings Hyprland back in ~2s, but the
# plugin, ydotoold and the shell take longer, and slating too early just
# measures the gap.
rig_wait_session() { # rig_wait_session [SECONDS=45]
    local deadline=$(( SECONDS + ${1:-45} )) sig
    while [ $SECONDS -lt $deadline ]; do
        sig=$(ls -t "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr" 2>/dev/null | head -1)
        if [ -n "$sig" ]; then
            RIG_ENV_OK=0
            if rig_env 2>/dev/null && hyprctl plugin list 2>/dev/null | grep -q "$RIG_NS"; then
                sleep 3     # let ydotoold and the shell finish coming up
                return 0
            fi
        fi
        sleep 2
    done
    echo "rig: no live session with the plugin loaded after ${1:-45}s" >&2
    return 1
}

# The baseline every slate restores: one snapshot of every registered plugin key,
# taken the first time a slate runs against this compositor instance -- which
# under suite.sh is before the first gate, i.e. off a session no gate has
# touched. Keyed by instance signature, so a compositor restart (x51 does one on
# purpose) re-reads the config-as-loaded rather than inheriting a stale file.
slate_keys() { _rig_need || return 1; python3 "$RIG_LIB_DIR/slate_keys.py" "$@"; }

rig_slate_baseline() {
    _rig_need || return 1
    RIG_SLATE_KEYS=$XDG_RUNTIME_DIR/rig-slate-$HYPRLAND_INSTANCE_SIGNATURE.keys
    if [ ! -s "$RIG_SLATE_KEYS" ]; then
        slate_keys snapshot > "$RIG_SLATE_KEYS" 2>/dev/null \
            || { rm -f "$RIG_SLATE_KEYS"
                 echo "slate: could not snapshot the plugin's config keys" >&2; return 1; }
        echo "slate: baseline captured, $(wc -l < "$RIG_SLATE_KEYS") keys -> $RIG_SLATE_KEYS" >&2
    fi
    export RIG_SLATE_KEYS
    return 0
}

gate_slate() { # gate_slate [LABEL] -- returns 1 if the session cannot be made clean
    _rig_need || return 1
    local label=${1:-slate}

    hyprctl plugin list 2>/dev/null | grep -q "$RIG_NS" \
        || { echo "slate($label): the plugin is not loaded" >&2; return 1; }

    # Order matters. Speed first (a slowmo'd close takes 20x as long), then the
    # overview, then the windows, then the outputs -- moving an output under a
    # live overview is the compositor-killer ov_off_settled documents.
    anim_restore
    ov_off_settled

    # Every toplevel dies. In this guest they are all somebody's fixture or a
    # stray the session raised on its own (gcr-prompter's "Unlock Login Keyring"
    # lands dead centre of the screen and overlaps every capture -- known since
    # 2026-08-08, and it is why this is a kill and not a filter). The shell's
    # bar and dock are LAYER surfaces and are not in `clients`, so they stay.
    hyprctl clients -j 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('pid',0) > 0: print(c['pid'])" | xargs -r kill -9 2>/dev/null
    sleep 1.2

    # Exactly one output, at the mode the whole coordinate system assumes.
    local m
    for m in $(hyprctl monitors all -j 2>/dev/null | python3 -c "
import json,sys
print(' '.join(m['name'] for m in json.load(sys.stdin) if m['name'].startswith('HEADLESS')))"); do
        hyprctl output remove "$m" >/dev/null 2>&1; sleep 0.4
    done
    hyprctl eval "return hl.monitor({output = [[$RIG_MON_NAME]], mode = [[$RIG_MON_MODE]], position = [[0x0]], scale = 1, disabled = false})" >/dev/null 2>&1
    sleep 1.5
    RIG_HEADLESS=0
    local got want_w rest want_h
    got=$(hyprctl monitors -j 2>/dev/null | python3 -c "
import json,sys
ms=json.load(sys.stdin)
print('%s %d %d' % (ms[0]['name'], ms[0]['width'], ms[0]['height']) if len(ms)==1 else 'none 0 0')")
    want_w=${RIG_MON_MODE%%x*}; rest=${RIG_MON_MODE#*x}; want_h=${rest%%@*}
    [ "$got" = "$RIG_MON_NAME $want_w $want_h" ] \
        || { echo "slate($label): outputs are '$got', wanted '$RIG_MON_NAME $want_w $want_h'" >&2; return 1; }

    # EVERY registered plugin option, back to the value the suite started with.
    #
    # This used to be the seven dock keys and anim_scale that gates were known to
    # write, with a comment saying the eighth would be found out the hard way.
    # It was: x30 leaves pressure_threshold, x24 leaves minimize_ms, y8 leaves
    # autohide_ms, and none of them was restored by anything but the gate's own
    # trap -- which does not fire when a gate is killed.
    #
    # The baseline is a SNAPSHOT of the session's own values, not Config.cpp's
    # defaults, and the difference matters here: the rice configures the plugin
    # (matugen's col_highlight and dock:background_opacity, 10-theme's
    # blur/render_power, 20-layout's workspace_gap, scale 0.82 against a
    # registered 0.9). Forcing defaults would re-theme the session between gates
    # and every pixel gate after that would measure a configuration nobody ships.
    # See lib/slate_keys.py.
    # ONLY THE KEYS THAT DRIFTED. Assigning all seventy-nine every time makes
    # `getoption` report set=true for every one of them, and x53_compat_alias's
    # A control requires its five probe keys to be UNSET -- it went red on a
    # clean build the first suite this ran (2026-08-12).
    rig_slate_baseline || return 1
    local _fix; _fix=$(slate_keys restore "$RIG_SLATE_KEYS" 2>/dev/null)
    [ -n "$_fix" ] && { hyprctl eval "$_fix" >/dev/null 2>&1; sleep 0.5; }
    # anim_scale AFTER the snapshot, not before: a baseline captured off a
    # session that had already been slowed would otherwise re-slow every gate.
    anim_restore

    # The seven dock keys stay asserted explicitly on their REGISTERED defaults:
    # nothing in this rice configures them, so this is both the restore check and
    # a guard on the snapshot itself -- if the baseline was captured off a dirty
    # session, this is where it says so instead of quietly propagating.
    cfg_dock "autohide=true, show_favorites=true, show_apps_button=true, show_trash=true, show_mounts=false, blur_size=-1, blur_passes=-1"
    sleep 0.5
    opt_want $RIG_KEY:dock:autohide true \
        || { echo "slate($label): dock config did not take" >&2; return 1; }

    dsp "hl.dsp.focus({workspace = 1})"; sleep 0.5

    # Re-measure the pointer mapping HERE, on the known-good output, and hand it
    # down to the gate through the environment.
    RIG_PTR_DIV=
    rig_calibrate || { echo "slate($label): pointer calibration failed" >&2; return 1; }
    warp 40 40      # park it out of every fixture's way
    sleep 0.3
    return 0
}
