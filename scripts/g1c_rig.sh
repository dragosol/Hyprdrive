#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC 13.11 G1, last clause -- COMPOSE/DEAD KEYS MUST START A
# SEARCH. Runs IN THE GUEST. Reuses g1_rig.sh's fixture (headless output, three
# kitty windows) so the frames carry no clock and idle frames are byte-stable.
#
# Two independent claims, and each needs a different shape of proof:
#
#   1. A COMPOSE SEQUENCE COMPOSES. `Compose ' e` must put "é" in the query,
#      not the raw "'e". A frame diff against ctrlA only proves "something was
#      typed" -- it cannot tell the two apart. So the gate compares the compose
#      frame against a RAW `' e` frame: if compose were passing through
#      untouched the two would be IDENTICAL, so identical is the failure and
#      "differs" is the pass. This is the only phase that can catch a silent
#      passthrough.
#
#   2. COMPOSE ALONE STARTS A SEARCH. Pressing Compose types nothing, so it is
#      invisible in a frame. It is observed through the ESC CASCADE instead:
#      with a search active the first ESC only clears and the overview STAYS
#      OPEN; with no search active the first ESC closes it. Frame 40 must look
#      open, and its control frame 50 must look closed.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
# Never hardcode wayland-1 -- a restarted GDM leaves the old wedged Hyprland
# holding it and clients connect to the corpse.
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
OUT=/mnt/host/g1

ov()  { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }
key() { ydotool key "$1:1" "$1:0"; sleep 0.30; }

# KEY_COMPOSE is evdev 127 -- the Menu key, which is what `compose:menu` binds.
K_ESC=1; K_E=18; K_APOS=40; K_MENU=127

TAG=${1:?usage: g1c_rig.sh <tag>}
MON=$(cat $OUT/mon)
shot() { grim -o "$MON" "$OUT/$TAG-$1.png"; }

ov off; sleep 1.0
ov on;  sleep 2.5

# Both controls are taken BEFORE any input: an "idle" frame captured after a
# keystroke inherits that keystroke's effect and restates the measurement.
shot 00-ctrlA; sleep 1.2; shot 01-ctrlB

# --- claim 1: the sequence composes -----------------------------------------
key $K_MENU; key $K_APOS; key $K_E; sleep 1.5; shot 10-compose
key $K_ESC; sleep 1.0          # clear
key $K_ESC; sleep 1.2          # close

ov on; sleep 2.5
key $K_APOS; key $K_E; sleep 1.5; shot 20-raw
key $K_ESC; sleep 1.0
key $K_ESC; sleep 1.2

# --- claim 2: compose alone activates the bar -------------------------------
sleep 1.0; shot 30-desktop      # what CLOSED looks like

ov on; sleep 2.5
key $K_MENU; sleep 0.6          # types nothing, but must make the search active
key $K_ESC;  sleep 1.5; shot 40-composeEsc   # ...so this ESC only CLEARS
key $K_ESC;  sleep 1.2                        # and this one closes

ov on; sleep 2.5
key $K_ESC; sleep 1.5; shot 50-escClose      # control: no search -> ESC closes

ls -la $OUT/$TAG-*.png
echo G1C_RUN_OK
