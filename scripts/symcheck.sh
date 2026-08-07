#!/usr/bin/env bash
# Every undefined symbol in the plugin must be provided by the host Hyprland
# binary, one of its libraries, one of the plugin's own libraries, or the
# plugin itself. Anything else is a lazy-bind time bomb.
#
# WHY THIS EXISTS. A shared object links happily with undefined symbols -- they
# are meant to be resolved against the host binary, which is how the plugin
# reaches Hyprland's own g_pHyprRenderer and friends. So a function that is
# declared in a header, called somewhere, and never defined produces NO build
# error at all. It produces `symbol lookup error: ... undefined symbol` at the
# FIRST CALL, which kills the compositor mid-session.
#
# Measured three times on 2026-08-07, all in one day:
#   * Dock::panelClick, defined inside Dock.cpp's anonymous namespace by
#     mistake, killed the session on the next mouse press.
#   * Locations::mount had been declared, wired to the dock menu's Mount row
#     and never written since X35 -- a compositor crash waiting for a click.
#   * houseEase, swept from global scope into OvInternal:: by the file split,
#     left _Z9houseEasebf dangling for TileChrome.cpp. ld.so's error path
#     exits 127; a garbage PLT jump segfaults "at X ip X". THE OLD VERSION OF
#     THIS SCRIPT MISSED IT: it grepped undefined symbols for 'ScrollOverview',
#     and a global-scope symbol contains no namespace to grep for. Hence the
#     rewrite: diff against what the hosts actually export, filter nothing.
set -u
SO=${1:-scrolloverview.so}
HOST=${2:-$(command -v Hyprland || echo /usr/bin/Hyprland)}
[ -f "$SO" ] || { echo "symcheck: no $SO"; exit 2; }
[ -f "$HOST" ] || { echo "symcheck: no host binary $HOST"; exit 2; }

# $1=="U": strong undefineds only -- weak ones (__gmon_start__ etc) may stay
# unresolved by design. @VERSION stripped so needed/provided spellings match.
NEEDED=$(nm -D --undefined-only "$SO" | awk '$1=="U"{print $2}' | sed 's/@.*//' | sort -u)
PROVIDED=$( { nm -D --defined-only "$SO" "$HOST";
              { ldd "$HOST"; ldd "$SO"; } | awk '$3 ~ /^\// {print $3}' | sort -u \
                | xargs -r -n1 nm -D --defined-only 2>/dev/null; } \
            | awk 'NF>=3{print $NF}' | sed 's/@.*//' | sort -u)

BAD=$(comm -23 <(printf '%s\n' "$NEEDED") <(printf '%s\n' "$PROVIDED"))
if [ -n "$BAD" ]; then
    echo "symcheck: FAIL -- undefined symbols nothing at runtime will provide:"
    printf '%s\n' "$BAD" | c++filt | sed 's/^/  /'
    echo
    echo "Loading this kills Hyprland at the first call, not at load."
    exit 1
fi

echo "symcheck: OK -- every undefined symbol has a provider ($(printf '%s\n' "$NEEDED" | wc -l) checked)"
