#!/usr/bin/env bash
# GATE x51_text_cache -- text served from the surviving glyph cache must be
# PIXEL-IDENTICAL to text rendered fresh. Frame A needs a COLD cache, so this
# wrapper restarts the guest compositor first (share/hyprrestart.sh, ~14s),
# waits for the NEW session, runs x51_gate.sh, then scripts the comparison the
# gate's promotion notes said was still manual:
#   A == B  (bytes)      cold text == cached text
#   B != C  (must-differ control: a typed query -- identical means the output
#            was starved and A==B proves nothing -> VOID, not a pass)
#
# RUN THIS OVER SSH (ssh -p 2222), never from a terminal inside the Hyprland
# session: the GDM restart would kill the very shell running it.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO"
source scripts/lib/rig.sh

export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
OLD_SIG=$(rig_sig)

# The restart is done HERE rather than by share/hyprrestart.sh. That script is
# the HOST's: every step of it goes through `ssh -p 2222 dragos@127.0.0.1`,
# which from inside the guest reaches nothing at all -- it printed "old
# signature: none", gave up, and x51 had been failing on that rather than on
# anything to do with the glyph cache (2026-08-11, zrig/gatefire/).
#
# GDM, not Hyprland. Exiting Hyprland alone drops to the greeter and the session
# never comes back, because autologin fires once per GDM START, not once per
# session (share/hyprrestart.sh:6-10).
#
# The quickshell prune is not housekeeping: it writes one instance directory per
# start, each log tens of MB, and a FULL /run/user/1000 breaks D-Bus activation
# outright -- which silently kills every GNOME search provider and was once
# diagnosed as a plugin bug for an hour (share/hyprrestart.sh:29-35).
rm -rf /run/user/1000/quickshell >/dev/null 2>&1 || true
sudo -n systemctl restart gdm \
    || { echo "FAIL: could not restart gdm from inside the guest" >&2; exit 1; }

# Wait for the NEW compositor: the instance signature must change (a restart
# mints a new instance dir) and rig_env must find a live session.
ok=0
for _ in $(seq 1 45); do
    sleep 2
    NEW_SIG=$(rig_sig)
    if [ -n "$NEW_SIG" ] && [ "$NEW_SIG" != "$OLD_SIG" ]; then
        RIG_ENV_OK=0
        if rig_env 2>/dev/null; then ok=1; break; fi
    fi
done
if [ "$ok" != 1 ]; then
    echo "FAIL: no fresh compositor session appeared within 90s of the restart" >&2
    exit 1
fi
sleep 8      # let the plugin and the rest of the session finish coming up

hyprwall_pause                 # x51_gate.sh stops the timer and never restarts it
trap hyprwall_resume EXIT

bash scripts/x51_gate.sh || { echo "FAIL: x51_gate.sh capture run failed" >&2; exit 1; }
alive_or_die "after the x51 capture run"

A=/mnt/host/x51_A_coldtext.png
B=/mnt/host/x51_B_cachedtext.png
C=/mnt/host/x51_C_control.png
for f in "$A" "$B" "$C"; do
    [ -s "$f" ] || { echo "FAIL: $f missing or empty -- capture did not land" >&2; exit 1; }
done

# `cmp -s "$A" "$B"` was the whole comparison until 2026-08-12, and these are
# WHOLE-OUTPUT grabs: the quickshell bar is in them, and its clock ticks in the
# twenty seconds of open/close laps between A and B. Measured on that run's own
# frames, A and B differed by 106 pixels and every one of them was inside
# x 800..916, y 10..25 -- the clock. Not one differing pixel where the plugin
# draws. x51_ident.py masks the layer-shell chrome (from x51_layers.json, which
# the capture run dumps) and grades what is left EXACTLY, zero tolerance,
# keeping the B != C starved-output control.
python3 "$REPO/scripts/x51_ident.py" "$A" "$B" "$C" /mnt/host/x51_layers.json
exit $?
