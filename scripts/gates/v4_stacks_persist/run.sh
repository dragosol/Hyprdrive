#!/usr/bin/env bash
# v4_stacks_persist -- V11 V4: a stack survives a compositor restart.
#
# THIS GATE RESTARTS THE COMPOSITOR ON PURPOSE and declares it with the
# `restarts-compositor` marker beside this file, which suite.sh honours -- see
# the DIED note in suite.sh: a gate that comes back on a different instance
# signature without that marker killed the compositor and everything it printed
# is void, including a PASS. x51_text_cache is the existing precedent.
#
# A separate gate from v4_stacks for exactly that reason: one restart, declared
# once, rather than a marker on the gate that does everything else.
#
# WHAT IT PROVES, and what it deliberately does not. It proves the STORE
# survives and the plugin re-reads it into a drawn cell. It does not re-prove
# the fan or the menu -- v4_stacks owns those, and repeating them here would
# make a restart gate slow without making it stronger.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=${RIG_EVIDENCE:-/mnt/host/zrig}/v4/persist; mkdir -p "$OUT"
FAIL=0

gate_slate v4_stacks_persist >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }

WORK=$(mktemp -d /tmp/v4persist.XXXXXXXX) || { echo "FAIL no fixture root"; exit 1; }
case "$WORK" in
    /tmp/v4persist.*) ;;
    *) echo "FAIL fixture root '$WORK' is not under /tmp/v4persist. -- refusing to run"; exit 1 ;;
esac
mkdir -p "$WORK/keep"
printf 'v4 persist fixture\n' > "$WORK/keep/one.txt"

cleanup() {
    case "${WORK:-}" in /tmp/v4persist.*) rm -rf "$WORK" ;; esac
    dsp "hl.plugin.hyprdrive.stack([[clear]])" >/dev/null 2>&1
    hyprwall_resume
}
trap cleanup EXIT

echo "--- pin, then restart the compositor under it"
hyprctl dispatch "hl.plugin.hyprdrive.stack([[pin $WORK/keep]])" >/dev/null 2>&1
sleep 1.0
grep -qF "$WORK/keep" "$RIG_STACKS" 2>/dev/null \
    || { echo "FAIL the pin did not reach the state file at $RIG_STACKS"; exit 1; }
cp "$RIG_STACKS" "$OUT/state-before-restart.txt"
BEFORE=$(cat "$RIG_STACKS")
SIG_BEFORE=$(rig_sig)
echo "    pinned; instance $SIG_BEFORE"

# THE RESTART IS DONE HERE, not by share/hyprrestart.sh. That script runs on
# the HOST and drives the guest from outside; invoked from inside the guest it
# returns cleanly and restarts nothing, which is exactly how x51_text_cache
# spent its life not reaching its own claim. The first run of this gate
# reproduced it: same instance signature either side, and the gate said so
# rather than passing.
sudo -n systemctl restart gdm >"$OUT/restart.log" 2>&1 \
    || { echo "FAIL could not restart gdm from inside the guest"; exit 1; }
rig_wait_session || { echo "FAIL the session did not come back"; exit 1; }
sleep 5

SIG_AFTER=$(rig_sig)
echo "    back up; instance $SIG_AFTER"
[ "$SIG_BEFORE" != "$SIG_AFTER" ] \
    || { echo "FAIL the compositor did not actually restart -- this gate measured nothing"; exit 1; }

# THE STORE. Byte-identical, because a plugin that rewrote it on load would
# pass a "still there" check while quietly dropping the view and sort columns.
AFTER=$(cat "$RIG_STACKS" 2>/dev/null || true)
cp "$RIG_STACKS" "$OUT/state-after-restart.txt" 2>/dev/null
if [ "$BEFORE" != "$AFTER" ]; then
    echo "FAIL the state file changed across the restart"
    echo "    before: $BEFORE"
    echo "    after : $AFTER"
    FAIL=1
else
    echo "    the state file is byte-identical across the restart"
fi

# AND THE CELL IS DRAWN. A store that survives but never reaches the dock is
# the failure this arm exists for: the whole claim is "the stack is still
# there", and a file on disk is not a stack the user can see.
cfg_dock "show_favorites=false, show_trash=false, show_mounts=false, show_apps_button=false, autohide=false"
sleep 0.8
pkill -x kitty 2>/dev/null; sleep 1.0
headless_on || exit 1
trap 'headless_off; cleanup' EXIT
dsp "hl.dsp.focus({monitor = \"$RIG_MON\"})"; sleep 0.4
fixture_kitty kitty 300 200 900 600 '#101820' 'clear; sleep infinity' || exit 1
killothers kitty; sleep 0.8

read -r SCX SCY <<< "$(hyprctl clients -j | python3 scripts/v4_stack_cell.py stack 0 1)"
grim -o "$RIG_MON" "$OUT/before-click.png"; sleep 0.3
warp_or_die "$SCX" "$SCY"; sleep 0.4
ydotool click 0x40; sleep 0.05; ydotool click 0x80
sleep 1.2
grim -o "$RIG_MON" "$OUT/after-click.png"; sleep 0.3

read -r PX PY PW PH <<< "$(hyprctl clients -j | python3 scripts/v4_stack_cell.py pill 1)"
# One file plus the action row: two rows, and nothing at a third.
python3 scripts/v4_stacks_gate.py fan "$OUT/after-click.png" "$OUT/before-click.png" "$SCX" "$PY" 2 || FAIL=1

echo
[ $FAIL = 0 ] && echo "PASS v4_stacks_persist" || echo "FAIL v4_stacks_persist"
exit $FAIL
