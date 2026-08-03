#!/bin/bash
# X26 end to end, driven from the HOST because every coordinate has to be
# measured off a frame from THIS run: the overview tile moves with the window
# count and the dock pill is centred, so both drift between runs. The previous
# fire drove these phases by hand and left nothing runnable behind.
set -eu
G=/home/dragos/hyprvm/g
SHARE=/home/dragos/hyprvm/share/x26

measure() { python3 /home/dragos/hyprvm/share/x26/x26_points.py "$1" "$2"; }

$G 'bash ~/overview-cpp/scripts/x26_open.sh'
read -r GX GY PCX PTOP < <(measure "$SHARE/open.png" points)
echo "grab $GX,$GY  pill centre $PCX top $PTOP"

# The hit: drop on the pill's centre.
$G "bash ~/overview-cpp/scripts/x26_drag.sh $GX $GY $PCX $((PTOP + 39)) dock"

# The near miss: 28px above the pill's top edge, deliberately close, so a reject
# proves the pill's own bounds rather than "the cursor never went near it".
$G 'bash ~/overview-cpp/scripts/x26_open.sh'
read -r GX GY PCX PTOP < <(measure "$SHARE/open.png" points)
$G "bash ~/overview-cpp/scripts/x26_drag.sh $GX $GY $PCX $((PTOP - 28)) miss"

# Hover: control frame first, then the icon target measured off that same frame.
$G 'bash ~/overview-cpp/scripts/x26_open.sh'
$G 'bash ~/overview-cpp/scripts/x26_hover.sh off'
read -r ICX ICY < <(measure "$SHARE/hover_off.png" icon)
echo "hover target $ICX,$ICY"
$G "bash ~/overview-cpp/scripts/x26_hover.sh on $ICX $ICY"

cd "$SHARE" && python3 x26_gate.py
