#!/usr/bin/env bash
# What Hyprdrive needs to build, installed when it is missing (user, 2026-11-04:
# "the native installer should just install all the prereqs along with the
# update, if the user doesn't have them").
#
# A Hyprland plugin is a C++ library loaded INTO the compositor: it calls
# Hyprland's own classes, so it is compiled against Hyprland's headers -- the
# exact version that runs, or Hyprland refuses to load it. Most distros ship
# those headers with Hyprland (Arch: the `hyprland` package; Debian:
# `hyprland-dev`). Some do not (Fedora's COPR builds: no hyprland-devel). There
# this script makes them itself, from Hyprland's source at the very commit the
# installed binary was built from, into a private SDK:
#   ${XDG_DATA_HOME:-~/.local/share}/hyprdrive/sdk/hyprland-<version>-<commit>
# Nothing of Hyprland is built or installed system-wide: the source headers are
# copied, the protocol headers generated with hyprwayland-scanner, and version.h
# filled in from the binary's own `Hyprland --version-json`, so the plugin's
# ABI hash is the running compositor's.
#
#   prereqs.sh            check; install what is missing (asks first); make the SDK
#   prereqs.sh --yes      ...without asking (also HYPRDRIVE_YES=1)
#   prereqs.sh --make     the Makefile's call: as above, messages on stderr, and
#                         the SDK's pkgconfig dir (or nothing) on stdout
#   prereqs.sh --pc-path  only print that dir; never installs anything
#   prereqs.sh --dry-run  say what would be installed or built, change nothing
# HYPRLAND_BIN picks the Hyprland to build for; HYPRDRIVE_PREREQS=0 skips the
# whole check (a packager's build root).
set -uo pipefail

MODE=run YES=${HYPRDRIVE_YES:-0} DRY=0
for a in "$@"; do
    case $a in
        --yes|-y) YES=1 ;;
        --make) MODE=make ;;
        --pc-path) MODE=pc ;;
        --dry-run) DRY=1 ;;
        *) echo "prereqs.sh: unknown option $a" >&2; exit 2 ;;
    esac
done
[ "$MODE" = make ] && exec 3>&1 1>&2 || exec 3>&1
say() { printf 'hyprdrive: %s\n' "$*" >&2; }
die() { say "$*"; exit 1; }
[ "${HYPRDRIVE_PREREQS:-1}" = 0 ] && exit 0

HERE=$(cd "$(dirname "$0")/.." && pwd)
DATA=${XDG_DATA_HOME:-$HOME/.local/share}/hyprdrive
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/hyprdrive
HYPR=${HYPRLAND_BIN:-$(command -v Hyprland 2>/dev/null || true)}

# ---- the Hyprland to build for ------------------------------------------------
VJSON=""
# (Hyprland refuses to start, even for --version-json, without XDG_RUNTIME_DIR:
# a TTY or sudo shell may not have one.)
[ -n "$HYPR" ] && [ -x "$HYPR" ] && VJSON=$(XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}} "$HYPR" --version-json 2>/dev/null || true)
jget() { printf '%s\n' "$VJSON" | sed -n "s/^ *\"$1\": *\"\\(.*\\)\",\\{0,1\\}$/\\1/p" | head -n 1; }
HVER=$(jget version) HCOMMIT=$(jget commit)
SDK=""
[ -n "$HVER" ] && [ -n "$HCOMMIT" ] && SDK=$DATA/sdk/hyprland-$HVER-${HCOMMIT:0:12}

have() { command -v "$1" >/dev/null 2>&1; }
pc_ok() { have pkg-config && pkg-config --exists "$1" 2>/dev/null; }
# The system's headers fit when they are this Hyprland's version.
system_headers() { pc_ok hyprland && [ "$(pkg-config --modversion hyprland 2>/dev/null)" = "$HVER" ]; }
sdk_ready() { [ -n "$SDK" ] && [ "$(cat "$SDK/.complete" 2>/dev/null)" = "$HCOMMIT" ]; }

if [ "$MODE" = pc ]; then
    [ -n "$HVER" ] && ! system_headers && sdk_ready && echo "$SDK/share/pkgconfig" >&3
    exit 0
fi
[ -n "$HYPR" ] || die "Hyprland is not installed (no Hyprland on PATH): install it first."
[ -n "$HVER" ] || die "$HYPR --version-json said nothing usable."

# ---- what is missing ------------------------------------------------------------
PM=""
for p in pacman dnf zypper apt-get; do have $p && { PM=$p; break; }; done

# Modules: the plugin's own (Makefile PKGS), and what hyprland.pc requires.
LUA=$(sh "$HERE/scripts/lua_pc.sh" 2>/dev/null || echo lua)
MODS="pixman-1 libdrm pangocairo cairo fontconfig libinput libudev wayland-server xkbcommon libsystemd gio-2.0 gio-unix-2.0
      xcb $LUA aquamarine hyprcursor hyprgraphics hyprlang hyprutils egl xcb-render xcb-xfixes xcb-icccm xcb-composite xcb-res xcb-errors"
TOOLS="c++ make pkg-config readelf python3"
# Headers Hyprland's own headers include without hyprland.pc naming them.
HEADERS="glslang/Include/glslang_c_interface.h"
hdr_ok() { have c++ && printf '#include <%s>\n' "$1" | c++ -std=c++2b -E -x c++ - >/dev/null 2>&1; }
NEED_SDK=0
if ! system_headers; then
    case $PM in
        pacman|apt-get) MODS="$MODS hyprland" ;; # their Hyprland package carries the headers
        *) NEED_SDK=1 ;;
    esac
fi
missing_pkgs() {
    local out=() m t
    for t in $TOOLS $( [ $NEED_SDK = 1 ] && echo "git hyprwayland-scanner" ); do have "$t" || out+=("tool:$t"); done
    [ $NEED_SDK = 1 ] && MODS2="$MODS wayland-protocols wayland-scanner" || MODS2=$MODS
    for m in $MODS2; do pc_ok "$m" || out+=("pc:$m"); done
    for h in $HEADERS; do hdr_ok "$h" || out+=("h:$h"); done
    printf '%s\n' "${out[@]}"
}
# One requirement -> the package that provides it, per package manager.
pkg_for() {
    local kind=${1%%:*} name=${1#*:}
    if [ "$kind" = h ]; then
        case $name in
            glslang/*) case $PM in pacman) echo glslang ;; apt-get) echo glslang-dev ;; *) echo glslang-devel ;; esac ;;
        esac
        return
    fi
    case $PM in
        dnf|zypper)
            if [ "$kind" = pc ]; then echo "pkgconfig($name)"; return; fi
            case $name in c++) echo gcc-c++ ;; pkg-config) [ $PM = dnf ] && echo pkgconf-pkg-config || echo pkg-config ;;
                readelf) echo binutils ;; *) echo "$name" ;; esac ;;
        pacman)
            case $name in
                c++) echo gcc ;; pkg-config) echo pkgconf ;; readelf) echo binutils ;; python3) echo python ;;
                pixman-1) echo pixman ;; pangocairo) echo pango ;; libudev|libsystemd) echo systemd-libs ;;
                wayland-server|wayland-scanner) echo wayland ;; xkbcommon) echo libxkbcommon ;;
                gio-2.0|gio-unix-2.0) echo glib2 ;; lua*) echo lua ;; xcb|xcb-render|xcb-xfixes|xcb-composite|xcb-res) echo libxcb ;;
                xcb-icccm) echo xcb-util-wm ;; xcb-errors) echo xcb-util-errors ;; egl) echo libglvnd ;;
                *) echo "$name" ;;
            esac ;;
        apt-get)
            case $name in
                c++) echo g++ ;; readelf) echo binutils ;; pixman-1) echo libpixman-1-dev ;; pangocairo) echo libpango1.0-dev ;;
                cairo) echo libcairo2-dev ;; fontconfig) echo libfontconfig-dev ;; libinput) echo libinput-dev ;;
                libudev) echo libudev-dev ;; libsystemd) echo libsystemd-dev ;; libdrm) echo libdrm-dev ;;
                wayland-server|wayland-scanner) echo libwayland-dev ;; xkbcommon) echo libxkbcommon-dev ;;
                gio-2.0|gio-unix-2.0) echo libglib2.0-dev ;; lua*) echo liblua5.4-dev ;; xcb) echo libxcb1-dev ;;
                xcb-render) echo libxcb-render0-dev ;; xcb-xfixes) echo libxcb-xfixes0-dev ;; xcb-icccm) echo libxcb-icccm4-dev ;;
                xcb-composite) echo libxcb-composite0-dev ;; xcb-res) echo libxcb-res0-dev ;; xcb-errors) echo libxcb-errors-dev ;;
                egl) echo libegl-dev ;; aquamarine|hyprcursor|hyprgraphics|hyprlang|hyprutils) echo "lib$name-dev" ;;
                hyprland) echo hyprland-dev ;; *) echo "$name" ;;
            esac ;;
    esac
}

# A terminal to ask on (and for sudo): one that really opens, not just exists.
tty_ok() { { : </dev/tty; } 2>/dev/null; }
install_reqs() { # $@ = requirements (tool:x pc:x h:x)
    local PKGS r p
    PKGS=$(for r in "$@"; do pkg_for "$r"; done | sort -u)
    # Arch: only what is not installed yet -- `pacman -S` of an installed package
    # is an upgrade, and a lone upgrade is a partial one pacman can refuse.
    [ "$PM" = pacman ] && PKGS=$(for p in $PKGS; do pacman -Q "$p" >/dev/null 2>&1 || echo "$p"; done)
    PKGS=$(echo $PKGS)
    [ -n "$PKGS" ] || return 0
    case $PM in
        pacman) CMD=(pacman -S --needed --noconfirm $PKGS) ;;
        dnf) CMD=(dnf install -y $PKGS) ;;
        zypper) CMD=(zypper --non-interactive install $PKGS) ;;
        apt-get) CMD=(apt-get install -y $PKGS) ;;
    esac
    say "to build Hyprdrive, this system needs: $(echo "$@" | sed 's/pc://g; s/tool://g; s/h://g')"
    say "  -> ${CMD[*]}"
    [ $DRY = 1 ] && return 0
    if [ "$YES" != 1 ]; then
        tty_ok || die "run it yourself (as root), then build again."
        printf 'hyprdrive: install them now? [y/N] ' >&2
        read -r ans </dev/tty || ans=""
        [[ $ans == [yY]* ]] || die "not installed; the build needs them."
    fi
    if [ "$(id -u)" = 0 ]; then "${CMD[@]}"
    elif have sudo && tty_ok; then sudo "${CMD[@]}" </dev/tty
    elif have pkexec; then pkexec "${CMD[@]}"
    else die "need root to install them: run it yourself, then build again."; fi || {
        [ "$PM" = pacman ] && say "if pacman refused a partial upgrade, update the system first (pacman -Syu)"
        [ "$PM" = dnf ] && say "if dnf says a package is excluded, a repo's includepkgs/excludepkgs keeps it out"
        die "the package manager failed."
    }
    hash -r
}

MISSING=$(missing_pkgs)
if [ -n "$MISSING" ]; then
    [ -n "$PM" ] || die "missing, and no package manager I know (pacman, dnf, zypper, apt): $(echo $MISSING)"
    # The tools first: without pkg-config every library looks missing.
    TOOLREQS=$(printf '%s\n' $MISSING | grep '^tool:' || true)
    if [ -n "$TOOLREQS" ] && ! have pkg-config; then
        install_reqs $TOOLREQS
        [ $DRY = 1 ] && exit 0
        MISSING=$(missing_pkgs)
    fi
    [ -n "$MISSING" ] && install_reqs $MISSING
    [ $DRY = 1 ] && exit 0
    MISSING=$(missing_pkgs)
    [ -z "$MISSING" ] || die "still missing after the install: $(echo $MISSING)"
fi

# The distro's Hyprland package may have brought headers of this version after all.
system_headers && exit 0
[ "$NEED_SDK" = 1 ] || NEED_SDK=1

# ---- the private SDK ------------------------------------------------------------
if sdk_ready; then echo "$SDK/share/pkgconfig" >&3; exit 0; fi
say "no Hyprland $HVER headers on this system: making them from Hyprland's source at ${HCOMMIT:0:12} (once per Hyprland version)"
[ $DRY = 1 ] && exit 0
for t in git hyprwayland-scanner python3; do have $t || die "$t is needed to make the headers"; done
SRC=$CACHE/hyprland-src
mkdir -p "$CACHE" "$DATA/sdk"
if [ ! -d "$SRC/.git" ]; then
    rm -rf "$SRC"
    git init -q "$SRC" && git -C "$SRC" remote add origin https://github.com/hyprwm/Hyprland.git || die "git init failed"
fi
git -C "$SRC" fetch -q --depth 1 origin "$HCOMMIT" || die "could not fetch Hyprland $HCOMMIT from GitHub"
git -C "$SRC" checkout -q --force --detach "$HCOMMIT" || die "could not check out $HCOMMIT"
[ "$(git -C "$SRC" rev-parse HEAD)" = "$HCOMMIT" ] || die "the fetched source is not $HCOMMIT"
# The shader includes Hyprland generates as it configures (its CMakeLists runs
# this first), so the copied headers are the whole set.
if [ -f "$SRC/scripts/generateShaderIncludes.sh" ]; then
    (cd "$SRC" && sh ./scripts/generateShaderIncludes.sh >/dev/null) || die "generating Hyprland's shader includes failed"
fi
HPROTO=""
if pc_ok hyprland-protocols; then HPROTO=$(pkg-config --variable=pkgdatadir hyprland-protocols)
else
    git -C "$SRC" submodule update -q --init --depth 1 subprojects/hyprland-protocols || die "could not fetch hyprland-protocols"
    HPROTO=$SRC/subprojects/hyprland-protocols
fi
TMP=$(mktemp -d "$DATA/sdk/.make.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
VJSON="$VJSON" python3 - "$SRC" "$TMP" "$HPROTO" \
    "$(pkg-config --variable=pkgdatadir wayland-protocols)" "$(pkg-config --variable=pkgdatadir wayland-scanner)" <<'PY' || die "making the headers failed"
import json, os, re, shutil, subprocess, sys
src, out, hproto, wlproto, wlscan = sys.argv[1:6]
v = json.loads(os.environ["VJSON"])
inc = os.path.join(out, "include", "hyprland")
gen = os.path.join(out, ".protocols")
os.makedirs(os.path.join(inc, "protocols"))
os.makedirs(gen)
os.makedirs(os.path.join(out, "share", "pkgconfig"))
# 1. Hyprland's own headers, as `make installheaders` copies them.
for root, _, files in os.walk(os.path.join(src, "src")):
    for f in files:
        if f.endswith((".hpp", ".h", ".inc")):
            rel = os.path.relpath(os.path.join(root, f), src)
            os.makedirs(os.path.dirname(os.path.join(inc, rel)), exist_ok=True)
            shutil.copy2(os.path.join(src, rel), os.path.join(inc, rel))
# 2. version.h, from the binary that will load the plugin.
def ver(key):
    s = v.get(key) or "0.0.0"
    return (s.split(".") + ["0", "0", "0"])[:3]
esc = lambda s: str(s).replace("\\", "\\\\").replace('"', "'")
vals = {
    "GIT_COMMIT_HASH": v["commit"], "GIT_BRANCH": v.get("branch", ""), "GIT_COMMIT_MESSAGE": esc(v.get("commit_message", "")),
    "GIT_COMMIT_DATE": v.get("commit_date", ""), "GIT_DIRTY": "dirty" if v.get("dirty") else "clean", "GIT_TAG": v.get("tag", ""),
    "GIT_COMMITS": v.get("commits", ""), "AQUAMARINE_VERSION": v.get("buildAquamarine", ""),
    "AQUAMARINE_VERSION_MAJOR": ver("buildAquamarine")[0], "AQUAMARINE_VERSION_MINOR": ver("buildAquamarine")[1],
    "AQUAMARINE_VERSION_PATCH": ver("buildAquamarine")[2], "HYPRLANG_VERSION": v.get("buildHyprlang", ""),
    "HYPRUTILS_VERSION": v.get("buildHyprutils", ""), "HYPRCURSOR_VERSION": v.get("buildHyprcursor", ""),
    "HYPRGRAPHICS_VERSION": v.get("buildHyprgraphics", ""),
}
tpl = open(os.path.join(src, "src", "version.h.in")).read()
h = re.sub(r"@([A-Z_]+)@", lambda m: str(vals[m.group(1)]) if m.group(1) in vals else m.group(0), tpl)
left = re.findall(r"@[A-Z_]+@", h)
if left:
    sys.exit("version.h.in has fields I do not know: %s" % " ".join(left))
open(os.path.join(inc, "src", "version.h"), "w").write(h)
# 3. The protocol headers: every protocolnew() in CMakeLists.txt, generated as its build does.
cm = open(os.path.join(src, "CMakeLists.txt")).read()
calls = re.findall(r'protocolnew\(\s*"([^"]*)"\s+"([^"]*)"\s+(true|false)\s*\)', cm)
if len(calls) < 10:
    sys.exit("found only %d protocols in CMakeLists.txt" % len(calls))
for path, name, external in calls:
    path = path.replace("${HYPRLAND_PROTOCOLS}", hproto)
    base = (path if os.path.isabs(path) else os.path.join(src, path)) if external == "true" else os.path.join(wlproto, path)
    subprocess.run(["hyprwayland-scanner", os.path.join(base, name + ".xml"), gen + "/"], check=True, stdout=subprocess.DEVNULL)
subprocess.run(["hyprwayland-scanner", "--wayland-enums", os.path.join(wlscan, "wayland.xml"), gen + "/"], check=True, stdout=subprocess.DEVNULL)
for f in os.listdir(gen):
    if re.search(r"\.h", f):
        shutil.copy2(os.path.join(gen, f), os.path.join(inc, "protocols", f))
for f in os.listdir(os.path.join(src, "protocols")):
    if re.search(r"\.h", f):
        shutil.copy2(os.path.join(src, "protocols", f), os.path.join(inc, "protocols", f))
shutil.rmtree(gen)
# 4. hyprland.pc, from its template.
mins = dict(re.findall(r"set\((\w+_MINIMUM_VERSION)\s+([\w.]+)\)", cm))
pc = open(os.path.join(src, "hyprland.pc.in")).read()
xw = ", xcb, xcb-render, xcb-xfixes, xcb-icccm, xcb-composite, xcb-res, xcb-errors" if "no xwayland" not in " ".join(v.get("flags", [])) else ""
rep = {"PREFIX": out.replace(os.sep + os.path.basename(out), "") , "INCLUDEDIR": "include", "HYPRLAND_VERSION": v["version"], "PKGCONFIG_XWAYLAND_DEPENDENCIES": xw}
rep.update(mins)
pc = re.sub(r"@(\w+)@", lambda m: rep.get(m.group(1), m.group(0)), pc)
if re.search(r"@\w+@", pc):
    sys.exit("hyprland.pc.in has fields I do not know: %s" % re.findall(r"@\w+@", pc))
open(os.path.join(out, "share", "pkgconfig", "hyprland.pc"), "w").write(pc)
print(len(calls) + 1)
PY
# The .pc names its own directory: written for TMP, it must name SDK.
sed -i "s|^prefix=.*|prefix=$SDK/include|" "$TMP/share/pkgconfig/hyprland.pc"
echo "$HCOMMIT" > "$TMP/.complete"
rm -rf "$SDK" && mv "$TMP" "$SDK" || die "could not move the SDK into place"
trap - EXIT
say "Hyprland $HVER headers ready in $SDK"
echo "$SDK/share/pkgconfig" >&3
