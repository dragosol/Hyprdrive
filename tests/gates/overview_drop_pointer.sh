#!/usr/bin/env bash
# overview_drop_pointer -- a tile dragged from a Mosaic desktop onto a desktop in the strip: the pointer stays where the hand left it.
# Owner, 2026-11-14: "if i move an app in overview from a mosaic desktop with
# multiple windows, onto a new desktop after I drop the app it tries to move
# my mouse" ("moving it from its tile to a desktop strip desktop").
# The desktop left behind pans to its next window, and the pointer used to ride
# that pan (rideCursor) although it was on the overview, not on the canvas.
# Asserts (mosaic + infinite canvas, 1920x1080; desktop 1: a1 a2 a3 at 1100x900,
# a3 focused and dragged; desktop 2: b1; the drop is on desktop 2's strip card):
#   1. the dragged window is on the desktop it was dropped on
#   2. for 2 s after the drop the pointer is within 2 px of the drop point
# Fails on 1.9.62 (a7230ff): the pointer slides from 880,165 to 773,165.
source "$(dirname "$0")/lib.sh"
gate_begin odp
rig_start
cfg '{general={layout="mosaic"}}'
cfg '{plugin={hyprdrive={mosaic={infinite_canvas=true}}}}'
go 2; kw b1 700 450; go 1; kw a1 1100 900; kw a2 1100 900; kw a3 1100 900; focus "$(addr_of a3)"; sleep 0.5
settle 3 geom
$R overview >/dev/null; sleep 1.2
W=a3
T=$(dbg tile "$W" | grep -o "tile $W [0-9 ]*"); set -- $T
[ $# -ge 6 ] || { check "debug tile $W answers in the overview" 0 "$(dbg tile "$W" | tail -1)"; gate_end; }
SX=$(( $3 + $5 / 2 )); SY=$(( $4 + $6 / 2 )); DX=880; DY=165
$R ptr drag $SX $SY $DX $DY 30 400 >/dev/null
far=0; seen=""
for i in $(seq 1 20); do
    CP=$(hq cursorpos | tr -d ' '); x=${CP%,*}; y=${CP#*,}
    d=$(( (x - DX) * (x - DX) + (y - DY) * (y - DY) )); [ "$d" -gt 4 ] && { far=1; seen="$seen $CP"; }
    sleep 0.1
done
check "1: $W was moved off desktop 1" "$([ "$(win "$W" .workspace.id)" != 1 ] && echo 1)" "$W on $(win "$W" .workspace.id), $(ids)"
check "2: the pointer stays at the drop point ($DX,$DY)" "$(is "$far" 0)" "pointer seen at:$seen"
gate_end
