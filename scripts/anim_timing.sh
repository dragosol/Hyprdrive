#!/usr/bin/env bash
# How long does the overview actually take to open, and to close?
#
# A full-screen grim is ~500ms here, which is longer than the animation it would
# be timing. A 240x120 crop is ~39ms, so the animation is sampled through a
# keyhole instead: one region that is 100% different between open and shut
# (picked by measuring, not by eye -- see the region search in the notes), polled
# until it stops changing. Time-to-settle IS the duration.
set -u
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=$(basename $(ls -t /run/user/1000/wayland-* | grep -v lock | head -1))
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)

REGION="2280,1140 240x120"
TMP=/tmp/animt
mkdir -p $TMP

dsp() { hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }
tog() { dsp "hl.plugin.scrolloverview.overview([[toggle]])"; }
key() { hyprctl eval "return hl.config({ plugin = { scrolloverview = { $1 = $2 } } })" >/dev/null; }

# Poll the keyhole until two consecutive grabs are identical, i.e. the motion
# stopped. Reports milliseconds from the toggle to that point.
settle_ms() {
    local t0 prev="" cur n=0
    rm -f $TMP/*.png
    t0=$(date +%s%N)
    "$@"
    while [ $n -lt 60 ]; do
        grim -g "$REGION" $TMP/s$n.png 2>/dev/null
        cur=$(md5sum $TMP/s$n.png | cut -d' ' -f1)
        if [ -n "$prev" ] && [ "$cur" = "$prev" ]; then
            echo $(( ( $(date +%s%N) - t0 ) / 1000000 ))
            return
        fi
        prev=$cur
        n=$((n + 1))
    done
    echo "-1"
}

run_pair() {
    local label="$1"
    dsp "hl.plugin.scrolloverview.overview([[off]])"; sleep 2.0
    local o=$(settle_ms tog); sleep 2.0
    local c=$(settle_ms tog); sleep 2.0
    echo "  $label: open ${o}ms  close ${c}ms"
}

echo "Each number includes ~39ms of grab latency for the final sample."
key open_speed 3.0; key close_speed 2.2; sleep 0.5
run_pair "defaults      (open 3.0 / close 2.2)"

# The keys are only real if changing them changes the measurement. A close
# deliberately slowed past the open is the clearest proof of that.
key close_speed 6.0; sleep 0.5
run_pair "close slowed  (open 3.0 / close 6.0)"

key close_speed 2.2; sleep 0.5
dsp "hl.plugin.scrolloverview.overview([[off]])"
