#!/usr/bin/env bash
# Every symbol the plugin declares in its OWN namespace must be defined in it.
#
# WHY THIS EXISTS. A shared object links happily with undefined symbols -- they
# are meant to be resolved against the host binary, which is how the plugin
# reaches Hyprland's own g_pHyprRenderer and friends. So a function that is
# declared in a header, called somewhere, and never defined produces NO build
# error at all. It produces `Hyprland: symbol lookup error: ... undefined
# symbol` at the FIRST CALL, which aborts the compositor mid-session.
#
# Measured twice on 2026-08-07, both in one afternoon:
#   * Dock::panelClick, defined inside Dock.cpp's anonymous namespace by
#     mistake, killed the session on the next mouse press.
#   * Locations::mount had been declared, wired to the dock menu's Mount row
#     and never written since X35 -- a compositor crash waiting for a click.
#
# Anything undefined and NOT in the ScrollOverview namespace is Hyprland's to
# provide and is left alone; anything undefined INSIDE it is the plugin failing
# to define its own function.
set -u
SO=${1:-scrolloverview.so}
[ -f "$SO" ] || { echo "symcheck: no $SO"; exit 2; }

BAD=$(nm -D --undefined-only "$SO" | grep 'ScrollOverview' || true)
if [ -n "$BAD" ]; then
    echo "symcheck: FAIL -- the plugin does not define its own symbols:"
    echo "$BAD" | c++filt | sed 's/^/  /'
    echo
    echo "Loading this would abort Hyprland at the first call, not at load."
    exit 1
fi

echo "symcheck: OK -- every ScrollOverview symbol is defined"
