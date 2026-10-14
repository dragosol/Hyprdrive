#!/usr/bin/env bash
# hl.sh -- a throwaway HEADLESS Hyprland for hyprdrive tests, run as the
# `hyprtest` user on fedora. Nothing touches a physical monitor or a seat.
#
# Why it is nested: Hyprland 0.56 always asks aquamarine for HEADLESS
# (mandatory) + DRM (if available) + Wayland (fallback). A headless backend has
# no DRM fd, so on its own it has no allocator ("Cannot open backend: no
# allocator available") -- there is no HYPRLAND_HEADLESS_ONLY in 0.56 (the
# hyprtester sets it, the binary never reads it; Compositor.cpp: "TODO:
# headless only"). DRM needs a libseat session, which hyprtest (reached via
# sudo, no logind session) does not have. So the harness runs an OUTER
# compositor that is itself headless -- `mutter --headless --virtual-monitor`
# (render nodes only, "using no mode setting") -- and Hyprland nests in it via
# the Wayland backend, which gives aquamarine a render node + allocator. Then
# Hyprland's own HEADLESS-n outputs work, and the nested WL-1 window is
# disabled. LIBSEAT_BACKEND=logind is pinned so libseat can never fall back to
# opening /dev/dri/card* directly.
#
# Usage (as dragos on fedora; every process runs as hyprtest via sudo -n -u):
#   hl.sh start [--no-plugin] [--so PATH]   start; loads the plugin via hyprctl
#   hl.sh stop                              exit Hyprland, kill everything, report cores
#   hl.sh status                            pids, monitors, plugin list
#   hl.sh h <hyprctl args...>               hyprctl against the instance
#   hl.sh eval '<lua>'                      = h eval '<lua>'
#   hl.sh overview [arg]                    hl.plugin.hyprdrive.overview(arg|"toggle all")
#   hl.sh shot <file.png> [OUTPUT]          grim of one output (default HEADLESS-1)
#   hl.sh win [cmd...]                      launch a client (default: kitty)
#   hl.sh mon2                              add HEADLESS-2 at 1920x0
#   hl.sh type <text>                       type via the instance's own virtual keyboard
#   hl.sh tap <Key>[+<Key>...]              e.g. tap Escape, tap Super+Tab (also down/up <Key>)
#   hl.sh key <wtype args...>               wtype (new device per call; not for the overview)
#   hl.sh ptr move X Y | click [left|right|middle] | down|up [btn]
#             | scroll DY | drag X1 Y1 X2 Y2 [steps]   pointer via wlr-virtual-pointer
#   hl.sh warp X Y                          hl.dsp.cursor.move (compositor warp, no device)
#   hl.sh sig                               instance signature
#   hl.sh log [n]                           tail of the instance's hyprland.log
#   hl.sh install [SO]                      copy a built hyprdrive.so into hyprtest's
#                                           ~/.local/lib/hyprdrive (default: repo build)
# Needs (hyprtest): pywayland for ptr/vkbd (pip install --user pywayland==0.4.18), wtype, grim, kitty, mutter.
# Env: HL_STATE (default /tmp/hyprdrive-hl), HL_USER (default hyprtest).
set -euo pipefail

HL_USER=${HL_USER:-hyprtest}
STATE=${HL_STATE:-/tmp/hyprdrive-hl}
RT=$STATE/rt
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { echo "hl: $*" >&2; exit 1; }

# ---------------------------------------------------------------- outer side
# Runs as the invoking user (dragos). Stages the script + helpers where
# hyprtest can read them, then re-runs itself as hyprtest.
if [ "${1:-}" != __inner ]; then
    [ "$(id -un)" = "$HL_USER" ] && die "run as your own user, not $HL_USER"
    cmd=${1:-}; [ -n "$cmd" ] || { sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 1; }
    shift || true
    as() { sudo -n -u "$HL_USER" "$@"; }
    case $cmd in
        install)
            so=${1:-$HERE/../../hyprdrive.so}
            [ -f "$so" ] || die "no .so at $so"
            tmp=$(mktemp -d /tmp/hl-install.XXXXXX); chmod 755 "$tmp"
            install -m644 "$so" "$tmp/hyprdrive.so"
            [ -f "$HERE/../../assets/scratchpad-symbolic.svg" ] && install -m644 "$HERE/../../assets/scratchpad-symbolic.svg" "$tmp/"
            as bash -c "install -Dm755 '$tmp/hyprdrive.so' ~/.local/lib/hyprdrive/hyprdrive.so &&
                        { [ ! -f '$tmp/scratchpad-symbolic.svg' ] || install -Dm644 '$tmp/scratchpad-symbolic.svg' ~/.local/lib/hyprdrive/scratchpad-symbolic.svg; } &&
                        sha256sum ~/.local/lib/hyprdrive/hyprdrive.so"
            rm -rf "$tmp"; exit 0 ;;
        shot)
            out=${1:-}; [ -n "$out" ] || die "usage: shot <file.png> [OUTPUT]"
            as env -i HOME=/nonexistent PATH=/usr/bin bash "$STATE/hl.sh" __inner shot "${2:-HEADLESS-1}" > "$out.tmp"
            [ -s "$out.tmp" ] || { rm -f "$out.tmp"; die "empty screenshot"; }
            mv "$out.tmp" "$out"; echo "$out"; exit 0 ;;
    esac
    if [ "$cmd" = start ]; then
        as bash -c "mkdir -p '$STATE' && chmod 755 '$STATE'"
    fi
    as test -d "$STATE" || die "not started (no $STATE)"
    # stage the current script + helpers (hyprtest cannot read dragos's home)
    for f in hl.sh vptr.py vkbd.py wlr-virtual-pointer-unstable-v1.xml virtual-keyboard-unstable-v1.xml; do
        as bash -c "cat > '$STATE/$f'" < "$HERE/$f"
    done
    since=$(date '+%Y-%m-%d %H:%M:%S')
    rc=0
    as env -i HOME=/nonexistent PATH=/usr/bin bash "$STATE/hl.sh" __inner "$cmd" "$@" || rc=$?
    if [ "$cmd" = stop ]; then
        # coredumpctl as dragos does list hyprtest's crashes (metadata only).
        st=$(as cat "$STATE/started-at" 2>/dev/null || echo "$since")
        # columns: DOW DATE TIME TZ PID UID GID SIG COREFILE EXE SIZE
        uid=$(id -u "$HL_USER")
        cores=$(coredumpctl list --no-legend --no-pager --since "$st" 2>/dev/null | awk -v u="$uid" '$6==u' || true)
        if [ -n "$cores" ]; then echo "hl: COREDUMPS since $st:"; echo "$cores"; rc=3
        else echo "hl: no coredumps since $st"; fi
    fi
    exit $rc
fi

# ---------------------------------------------------------------- inner side
# Runs as hyprtest with a scrubbed environment.
shift
export HOME=$(getent passwd "$(id -un)" | cut -d: -f6)
export USER=$(id -un) LOGNAME=$(id -un)
export PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin
export XDG_RUNTIME_DIR=$RT
export LIBSEAT_BACKEND=logind          # never the builtin/noop backend
export GIO_USE_VFS=local GSETTINGS_BACKEND=memory NO_AT_BRIDGE=1
unset WAYLAND_DISPLAY DISPLAY DBUS_SESSION_BUS_ADDRESS HYPRLAND_INSTANCE_SIGNATURE
SO_DEFAULT=$HOME/.local/lib/hyprdrive/hyprdrive.so

sig()   { cat "$STATE/sig" 2>/dev/null || die "no instance (not started?)"; }
wlsock(){ cat "$STATE/wl" 2>/dev/null || die "no wayland socket recorded"; }
hc()    { HYPRLAND_INSTANCE_SIGNATURE=$(sig) hyprctl "$@"; }
running(){ [ -f "$STATE/hypr.pid" ] && kill -0 "$(cat "$STATE/hypr.pid")" 2>/dev/null; }

# every process we launch carries XDG_RUNTIME_DIR=$RT and runs in its own
# session (setsid); our own shell and its subshells share our session id.
ours() {
    local p me
    me=$(ps -o sid= -p $$ | tr -d ' ')
    for p in $(pgrep -u "$(id -u)"); do
        [ "$(ps -o sid= -p "$p" 2>/dev/null | tr -d ' ')" = "$me" ] && continue
        { tr '\0' '\n' < /proc/$p/environ; } 2>/dev/null | grep -qx "XDG_RUNTIME_DIR=$RT" && echo "$p"
    done
    return 0
}

# A session bus with NO activatable services. With the stock session.conf the
# overview's search warm-up D-Bus-activated ~30 GNOME search providers
# (nautilus, firefox, gnome-software, evolution, goa...) inside the test.
write_busconf() {
    cat > "$STATE/bus.conf" <<XML
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <keep_umask/>
  <listen>unix:dir=$RT</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
XML
}

# pywayland bindings for the two input protocols (vptr.py, vkbd.py)
gen_proto() {
    [ -f "$STATE/py/hlproto/.ok" ] && return 0
    mkdir -p "$STATE/py/hlproto"
    python3 -m pywayland.scanner -i /usr/share/wayland/wayland.xml \
        "$STATE/wlr-virtual-pointer-unstable-v1.xml" "$STATE/virtual-keyboard-unstable-v1.xml" \
        -o "$STATE/py/hlproto" >/dev/null 2>&1 || die "pywayland scanner failed (pip install --user pywayland)"
    touch "$STATE/py/hlproto/.ok"
}

write_config() {
    cat > "$STATE/test.lua" <<'LUA'
-- hl.sh test config: vanilla Hyprland, nothing from ~/.config/hypr.
-- HEADLESS-1 is the test output; WL-1 (the nested window in the outer
-- headless mutter) is turned off once HEADLESS-1 exists (see hl.sh start).
hl.monitor({ output = "HEADLESS-1", mode = "1920x1080@60", position = "0x0",    scale = 1 })
hl.monitor({ output = "HEADLESS-2", mode = "1920x1080@60", position = "1920x0", scale = 1 })
hl.monitor({ output = "WL-1",       mode = "1920x1080@60", position = "-1920x0", scale = 1 })

hl.config({
    general  = { gaps_in = 5, gaps_out = 10, border_size = 2, layout = "dwindle" },
    decoration = { rounding = 8 },
    animations = { enabled = true },
    misc     = { disable_hyprland_logo = true, disable_splash_rendering = true,
                 force_default_wallpaper = 0, background_color = 0x202830 },
    xwayland = { enabled = false },
    debug    = { disable_logs = false, enable_stdout_logs = false },
})
hl.env("XCURSOR_SIZE", "24")
LUA
}

case ${1:-} in
start)
    shift
    plugin=1; so=$SO_DEFAULT
    while [ $# -gt 0 ]; do case $1 in
        --no-plugin) plugin=0 ;;
        --so) so=$2; shift ;;
        *) die "start: unknown arg $1" ;;
    esac; shift; done
    running && die "already running (hl.sh stop first)"
    [ -z "$(ours)" ] || die "leftover processes on $RT: $(ours | tr '\n' ' ') -- run hl.sh stop"
    rm -rf "$RT" "$STATE"/{sig,wl,*.pid,outer.log,hypr.out,py,nclients,client.*.log,vkbd.log,vkbd.fifo,vkbd.fifo.ack}
    mkdir -m700 "$RT"
    date '+%Y-%m-%d %H:%M:%S' > "$STATE/started-at"
    write_config; write_busconf
    cd /
    # 1. headless outer compositor (no seat, no KMS)
    setsid dbus-run-session --config-file="$STATE/bus.conf" -- mutter --headless --wayland --no-x11 \
        --virtual-monitor 1920x1080 --wayland-display outer-0 \
        > "$STATE/outer.log" 2>&1 < /dev/null &
    echo $! > "$STATE/outer.pid"
    for _ in $(seq 50); do [ -S "$RT/outer-0" ] && break; sleep 0.2; done
    [ -S "$RT/outer-0" ] || { tail "$STATE/outer.log"; die "outer mutter did not come up"; }
    # 2. Hyprland nested in it, with its own session bus like a real login
    #    (hyprdrive's search worker needs sd_bus_open_user; without a bus it
    #    exits and the next overview open hits std::terminate -- see report).
    #    hypr.pid is the dbus-run-session wrapper; it lives exactly as long
    #    as Hyprland does.
    WAYLAND_DISPLAY=outer-0 HYPRLAND_NO_SD_NOTIFY=1 HYPRLAND_NO_SD_VARS=1 \
        setsid dbus-run-session --config-file="$STATE/bus.conf" -- Hyprland -c "$STATE/test.lua" > "$STATE/hypr.out" 2>&1 < /dev/null &
    echo $! > "$STATE/hypr.pid"
    for _ in $(seq 75); do
        s=$(ls -t "$RT/hypr" 2>/dev/null | head -1 || true)
        [ -n "$s" ] && [ -S "$RT/hypr/$s/.socket.sock" ] && HYPRLAND_INSTANCE_SIGNATURE=$s hyprctl -j monitors >/dev/null 2>&1 && break
        running || { tail -20 "$STATE/hypr.out"; die "Hyprland died during startup"; }
        sleep 0.2
    done
    [ -n "${s:-}" ] || { tail -20 "$STATE/hypr.out"; die "no instance socket after 15 s"; }
    echo "$s" > "$STATE/sig"
    hc -j instances | python3 -c 'import json,sys; [print(i["wl_socket"]) for i in json.load(sys.stdin) if i["instance"]==sys.argv[1]]' "$s" > "$STATE/wl"
    # 3. the real test output, then retire the nested window
    hc output create headless HEADLESS-1 >/dev/null
    for _ in $(seq 25); do hc monitors | grep -q '^Monitor HEADLESS-1' && break; sleep 0.2; done
    hc eval 'hl.monitor({ output = "WL-1", disabled = true })' >/dev/null
    sleep 0.5
    # "started without start-hyprland" toast: expected here (start-hyprland is
    # a crash-restarting watchdog, which would hide crashes from a test)
    hc dismissnotify >/dev/null 2>&1 || true
    # a keyboard for the seat, or no window ever gets keyboard focus
    gen_proto
    WAYLAND_DISPLAY=$(wlsock) PYTHONPATH=$STATE/py HL_VKBD_FIFO=$STATE/vkbd.fifo setsid python3 "$STATE/vkbd.py" \
        > "$STATE/vkbd.log" 2>&1 < /dev/null &
    echo $! > "$STATE/vkbd.pid"
    echo "hl: Hyprland up, sig $s wayland $(wlsock)"
    hc monitors | grep '^Monitor'
    if [ $plugin = 1 ]; then
        [ -f "$so" ] || die "plugin not found: $so (hl.sh install, or --no-plugin)"
        r=$(hc plugin load "$so" 2>&1) || true
        echo "hl: plugin load: $r"
        running || { tail -30 "$STATE/hypr.out"; die "Hyprland died loading the plugin"; }
        hc plugin list
    fi
    ;;
stop)
    # input helpers first, while the display is still alive
    [ -f "$STATE/vkbd.pid" ] && kill "$(cat "$STATE/vkbd.pid")" 2>/dev/null || true
    if running; then
        hc eval 'hl.dispatch(hl.dsp.exit())' >/dev/null 2>&1 || true
        for _ in $(seq 25); do running || break; sleep 0.2; done
        running && { echo "hl: exit dispatcher ignored, SIGTERM"; kill "$(cat "$STATE/hypr.pid")"; sleep 2; }
    fi
    # keep the instance log for post-mortems
    s=$(cat "$STATE/sig" 2>/dev/null || true)
    [ -n "$s" ] && [ -f "$RT/hypr/$s/hyprland.log" ] && cp "$RT/hypr/$s/hyprland.log" "$STATE/hyprland.last.log"
    pids=$(ours)
    [ -n "$pids" ] && kill $pids 2>/dev/null || true
    sleep 1
    pids=$(ours)
    [ -n "$pids" ] && { echo "hl: SIGKILL $(echo $pids)"; kill -9 $pids 2>/dev/null || true; sleep 0.5; }
    pids=$(ours)
    [ -z "$pids" ] || die "processes survived: $pids"
    rm -rf "$RT" "$STATE"/{sig,wl,*.pid}
    echo "hl: stopped, no processes left on $RT (log kept: $STATE/hyprland.last.log)"
    ;;
status)
    running || { echo "hl: not running"; exit 1; }
    echo "hl: sig $(sig) wayland $(wlsock)"
    echo "hl: processes: $(ours | xargs -r ps -o comm= -p | tr '\n' ' ')"
    hc monitors | grep '^Monitor'; hc plugin list
    ;;
h)    shift; hc "$@" ;;
eval) shift; hc eval "$*" ;;
overview)
    shift; a=${1:-toggle all}
    hc eval "hl.dispatch(hl.plugin.hyprdrive.overview(\"$a\"))" ;;
sig)  sig ;;
log)  s=$(sig); tail -n "${2:-40}" "$RT/hypr/$s/hyprland.log" ;;
shot)
    # PNG on stdout; the outer side writes the file
    WAYLAND_DISPLAY=$(wlsock) grim -o "${2:-HEADLESS-1}" - ;;
win)
    shift; [ $# -gt 0 ] || set -- kitty
    cd /
    WAYLAND_DISPLAY=$(wlsock) setsid "$@" > "$STATE/client.$$.log" 2>&1 < /dev/null &
    echo "hl: launched $* (pid $!)"
    for _ in $(seq 25); do
        n=$(hc -j clients | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
        [ "$n" -gt "$(cat "$STATE/nclients" 2>/dev/null || echo 0)" ] && break; sleep 0.2
    done
    echo "${n:-0}" > "$STATE/nclients"; echo "hl: $n client(s) mapped"
    ;;
mon2)
    hc output create headless HEADLESS-2; sleep 0.5; hc monitors | grep '^Monitor' ;;
type|tap|down|up)
    # through the long-lived virtual keyboard (vkbd.py), one device for the
    # whole run -- what hyprdrive's overview needs (see vkbd.py)
    [ -p "$STATE/vkbd.fifo" ] || die "no vkbd fifo (not started?)"
    c=$1; shift; id=$$.$RANDOM
    printf '%s %s %s\n' "$id" "$c" "$*" > "$STATE/vkbd.fifo"
    for _ in $(seq 300); do
        [ "$(cat "$STATE/vkbd.fifo.ack" 2>/dev/null)" = "$id" ] && exit 0
        sleep 0.05
    done
    die "vkbd did not ack within 15 s" ;;
key)
    # wtype: a NEW virtual keyboard per call; fine for plain windows, but the
    # overview reacts to the new device (use type/tap there)
    shift; WAYLAND_DISPLAY=$(wlsock) wtype "$@" ;;
warp)
    hc eval "hl.dispatch(hl.dsp.cursor.move({ x = $2, y = $3 }))" ;;
ptr)
    shift
    gen_proto
    # absolute coordinates are layout coordinates; extents = layout bounding box
    ext=$(hc -j monitors | python3 -c 'import json,sys
m=[x for x in json.load(sys.stdin) if not x.get("disabled")]
print(max(x["x"]+x["width"] for x in m), max(x["y"]+x["height"] for x in m))')
    WAYLAND_DISPLAY=$(wlsock) PYTHONPATH=$STATE/py python3 "$STATE/vptr.py" $ext "$@" ;;
*) die "unknown command ${1:-} (see the header of hl.sh)" ;;
esac
