#!/usr/bin/env bash
# Did the overview actually get snappier? A/B of the OLD defaults (3.0 / 2.2)
# against the NEW ones (2.6 / 1.9), through the same keyhole anim_timing.sh
# uses -- a full-screen grim is ~500ms here, longer than the animation it would
# be timing, so a 240x120 crop is the only instrument that fits.
#
# The absolute numbers are grab-rate limited on this guest (the output is
# frame-starved while the host viewer is hidden), so only the DIFFERENCE between
# the two conditions is meaningful. Both are measured in the same session, back
# to back, for exactly that reason.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)

REGION="2280,1140 240x120"
TMP=/tmp/animab; mkdir -p $TMP

dsp() { hyprctl eval "return hl.dispatch($1)" >/dev/null 2>&1; }
tog() { dsp "hl.plugin.scrolloverview.overview([[toggle]])"; }
key() { hyprctl eval "return hl.config({ plugin = { scrolloverview = { $1 = $2 } } })" >/dev/null; }

settle_ms() {
    local t0 prev="" cur n=0
    rm -f $TMP/*.png
    t0=$(date +%s%N)
    "$@"
    while [ $n -lt 60 ]; do
        grim -g "$REGION" $TMP/s$n.png 2>/dev/null
        cur=$(md5sum $TMP/s$n.png | cut -d' ' -f1)
        if [ -n "$prev" ] && [ "$cur" = "$prev" ]; then
            echo $(( ( $(date +%s%N) - t0 ) / 1000000 )); return
        fi
        prev=$cur; n=$((n + 1))
    done
    echo "-1"
}

# Median of three: one sample of a frame-starved output is noise.
run3() {
    local label="$1" os=""; local cs=""
    for i in 1 2 3; do
        dsp "hl.plugin.scrolloverview.overview([[off]])"; sleep 1.6
        os="$os $(settle_ms tog)"; sleep 1.6
        cs="$cs $(settle_ms tog)"; sleep 1.6
    done
    local om=$(echo $os | tr ' ' '\n' | sort -n | sed -n 2p)
    local cm=$(echo $cs | tr ' ' '\n' | sort -n | sed -n 2p)
    printf '  %-28s open %4sms (%s)   close %4sms (%s)\n' "$label" "$om" "$os" "$cm" "$cs"
}

case "${1:-run}" in
fixture)
    systemctl --user stop hyprwall.timer 2>/dev/null
    dsp "hl.plugin.scrolloverview.overview([[off]])"; sleep 1
    pkill -x kitty 2>/dev/null; sleep 1.5
    for c in ANIMA ANIMB; do
        setsid kitty -c NONE --class $c -o background='#203040' -o background_opacity=1.0 \
            -o confirm_os_window_close=0 --hold sh -c clear >/dev/null 2>&1 </dev/null &
        sleep 2.2
    done
    hyprctl clients -j | python3 -c "import json,sys; print('clients:', len(json.load(sys.stdin)))"
    ;;
run)
    echo "compiled defaults:"
    hyprctl getoption plugin:scrolloverview:open_speed  | sed 's/^/  open_speed  /'
    hyprctl getoption plugin:scrolloverview:close_speed | sed 's/^/  close_speed /'
    echo
    echo "Each number includes ~39ms of grab latency for the final sample."
    key open_speed 3.0; key close_speed 2.2; sleep 0.5
    run3 "OLD (open 3.0 / close 2.2)"
    key open_speed 2.6; key close_speed 1.9; sleep 0.5
    run3 "NEW (open 2.6 / close 1.9)"
    dsp "hl.plugin.scrolloverview.overview([[off]])"
    ;;
esac
