#!/bin/bash
# X24 flight, end to end, driven from the HOST: the pill is centred and its
# width tracks the running-app count, so the icon has to be measured off a frame
# from THIS run rather than carried over from the last one.
set -eu
G=/home/dragos/hyprvm/g
SHARE=/home/dragos/hyprvm/share/x24

$G 'bash ~/overview-cpp/scripts/x24_click.sh setup'
read -r ICX ICY < <(python3 /home/dragos/hyprvm/share/x26/x26_points.py "$SHARE/open.png" icon)
echo "icon target $ICX,$ICY"
$G "bash ~/overview-cpp/scripts/x24_click.sh $ICX $ICY"

cd "$SHARE" && python3 x24_flight_gate.py
