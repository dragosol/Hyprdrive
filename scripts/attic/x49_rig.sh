#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC §13.12 X49 -- THE RESULTS ARE WIDE AND CATEGORISED.
# Runs IN THE GUEST on the fixture x48_rig.sh already placed. Grades on the
# HOST with x49_gate.py.
#
# The claim has two halves and they need different locators:
#
#   WIDE      the result rows span the width the TILES span, not the search
#             pill's 436 logical px. Measured off the one row that is findable
#             by colour -- the SELECTED row, drawn modifyA(1.F) -- so what is
#             graded is a row's real box and not a guess at the card's frosted
#             edge.
#   SECTIONS  there is more than ONE card. Walked with TAB: inside a card the
#             selection steps by ROWHL+ROWGAPL, but crossing into the next card
#             also costs two card paddings and the section gap. A step that is
#             half again the intra-card step IS a card boundary, and on a build
#             with a single flat panel no such step exists.
#
# TAB, never DOWN: DOWN goes to moveSelection() and walks the GRID's tile
# selection (scrollOverview.cpp:2413). Only Tab walks the result rows. This cost
# the X48 fire a run.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
SRC=/mnt/host/x48; OUT=/mnt/host/x49; mkdir -p $OUT

ov()  { hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[$1]]))" >/dev/null 2>&1; }
key() { ydotool key "$1:1" "$1:0"; sleep 0.30; }
K_ESC=1; K_TAB=15

# The QUERY decides whether there is anything to categorise, so it is an
# argument rather than a constant. Only ONE provider answers in this VM
# (org.gnome.Characters -- Settings and Calculator are not installed, Nautilus
# returns nothing), and the result cap is 5 SHARED with apps listed first, so a
# query that matches 5 apps starves every provider and yields exactly one
# section however correct the grouping code is. "kit" matches one app and
# leaves four slots for Characters: two cards, which is the smallest fixture
# that can show a boundary at all.
kc() { case "$1" in a) echo 30;; c) echo 46;; e) echo 18;; i) echo 23;; k) echo 37;; l) echo 38;; m) echo 50;;
                    o) echo 24;; r) echo 19;; s) echo 31;; t) echo 20;; *) echo "bad letter $1" >&2; exit 1;; esac; }

TAG=${1:?usage: x49_rig.sh <tag> [query]}
QUERY=${2:-kit}
MON=$(cat $SRC/mon)
shot() { grim -o "$MON" "$OUT/$TAG-$1.png"; }

systemctl --user stop hyprwall.timer 2>/dev/null

ov off; sleep 1.0
ov on;  sleep 2.5

# a0/a1 bracket the resting state: identical to each other, or the output is
# drifting and no diff below means anything.
shot 00-a0; sleep 1.2; shot 01-a1

for i in $(seq 1 ${#QUERY}); do key "$(kc "${QUERY:$((i-1)):1}")"; done
sleep 3.0                # G7 debounce, then the provider's own round trip

# Six steps is enough to leave the first card on any plausible grouping while
# staying inside the shared result cap.
for i in 1 2 3 4 5 6; do
    key $K_TAB; sleep 0.9
    shot "1$i-t$i"
done

key $K_ESC; sleep 1.5
ov off

ls -la $OUT/$TAG-*.png
echo X49_RUN_OK
