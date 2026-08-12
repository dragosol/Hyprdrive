#!/usr/bin/env bash
# x63_monitor_countdown -- the keep-these-settings leash, all three ways it ends.
#
# A monitor change is the one settings write that can take away the screen you
# would use to undo it, so the interesting question is never "does the dialog
# appear". It is "what undoes this when the thing that was supposed to undo it is
# gone". Three arms, and the third is the one worth having:
#
#   P1 EXPIRE   apply a scale, say nothing. The detached watcher puts it back.
#   P2 CONFIRM  apply, confirm, and wait PAST the deadline. It must still be
#               there -- a countdown that reverts a confirmed change is worse
#               than no countdown.
#   P3 CRASH    apply, then kill the watcher with the countdown still open, the
#               way a killed app takes its children. Nothing reverts it -- proved,
#               not assumed, by watching it stay wrong. Then `hdmon check`, which
#               the launcher runs before the window is drawn, and it goes back.
#
# The scale is measured off `hyprctl monitors -j`, not off the fragment: a
# fragment that says 1.25 while the output renders at 1.0 is the failure this
# would otherwise hide.
#
# 1.25 on a 2560x1600 output is 2048x1280 in layout pixels -- a whole number, so
# Hyprland takes it. A scale it rejects would leave the output at 1.0 and P1
# would pass for the wrong reason; the gate checks the change LANDED first.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=/mnt/host/zrig/phase11/x63; mkdir -p "$OUT"
FRAG=$HOME/.config/hypr/hyprdrive/45-monitors.lua
PENDING=${XDG_STATE_HOME:-$HOME/.local/state}/hyprdrive/monitor-pending.json
FAIL=0
bad() { echo "FAIL $*"; FAIL=1; }

gate_slate x63_monitor_countdown >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }

scale() { hyprctl monitors -j | python3 -c "
import json,sys
m=[x for x in json.load(sys.stdin) if x['name']=='$RIG_MON_NAME']
print('%.2f' % m[0]['scale'] if m else 'gone')"; }

cleanup() {
    python3 scripts/hdmon.py confirm >/dev/null 2>&1
    rm -f "$PENDING"
    pkill -f "hdmon[.]py watch" >/dev/null 2>&1
    # Put the fragment back to whatever it was before the gate, byte for byte.
    if [ -s "$OUT/frag.bak" ]; then cp "$OUT/frag.bak" "$FRAG"; else rm -f "$FRAG"; fi
    python3 - <<'PY' >/dev/null 2>&1
import json, pathlib
p = pathlib.Path.home() / ".local/state/hyprdrive/settings.json"
if p.exists():
    d = json.loads(p.read_text()); d.get("panes", {}).pop("monitors", None)
    p.write_text(json.dumps(d, indent=1))
PY
    hyprctl reload >/dev/null 2>&1
}
[ -e "$FRAG" ] && cp "$FRAG" "$OUT/frag.bak" || : > "$OUT/frag.bak"
trap cleanup EXIT

BASE=$(scale)
echo "preflight: $RIG_MON_NAME is at scale $BASE"
[ "$BASE" = "1.00" ] || bad "preflight: expected the session's own scale 1.00, got $BASE"
[ -e "$PENDING" ] && bad "preflight: a countdown was already pending before the gate started"

# ------------------------------------------------------------------ P1 EXPIRE --
echo
echo "--- P1 EXPIRE"
python3 scripts/hdmon.py apply --output "$RIG_MON_NAME" --scale 1.25 --timeout 6 | sed 's/^/    /'
sleep 2
S1=$(scale); echo "    scale while the countdown runs: $S1"
[ "$S1" = "1.25" ] || bad "P1: the change never landed (scale $S1) -- everything after this measures nothing"
LEFT=$(python3 scripts/hdmon.py pending)
echo "    pending says ${LEFT}s left"
[ "$LEFT" = none ] && bad "P1: nothing pending while the change is live"
sleep 8
S2=$(scale); echo "    scale after the deadline: $S2"
[ "$S2" = "$BASE" ] || bad "P1: the countdown expired and the scale is still $S2"
[ -e "$PENDING" ] && bad "P1: the pending record outlived the revert"
# The fragment must be back BYTE FOR BYTE. Not "absent" -- install-fragments.sh
# seeds an empty one, and "the file is gone" would have been a check that passed
# only on a machine where the app had never been installed.
if [ -s "$OUT/frag.bak" ]; then
    cmp -s "$OUT/frag.bak" "$FRAG" \
        && echo "    45-monitors.lua is byte-identical to what it was" \
        || bad "P1: the fragment came back different from what it was"
else
    [ -e "$FRAG" ] && bad "P1: a fragment that did not exist before the arm exists after it"
fi

# ----------------------------------------------------------------- P2 CONFIRM --
echo
echo "--- P2 CONFIRM"
python3 scripts/hdmon.py apply --output "$RIG_MON_NAME" --scale 1.25 --timeout 6 >/dev/null
sleep 1
python3 scripts/hdmon.py confirm | sed 's/^/    /'
sleep 9      # well past the deadline it would have had
S3=$(scale); echo "    scale $((9))s after a deadline that was confirmed away: $S3"
[ "$S3" = "1.25" ] || bad "P2: a confirmed change was reverted anyway (scale $S3)"
grep -q 'scale = 1.25' "$FRAG" || bad "P2: the fragment does not carry the confirmed scale"

# put it back the ordinary way, so P3 starts from the session's own value
python3 scripts/hdmon.py apply --output "$RIG_MON_NAME" --scale 1.0 --timeout 60 >/dev/null
python3 scripts/hdmon.py confirm >/dev/null
sleep 2
[ "$(scale)" = "$BASE" ] || bad "P2: could not get back to $BASE"

# ------------------------------------------------------------------- P3 CRASH --
echo
echo "--- P3 CRASH (the watcher dies with the app, the countdown does not)"
python3 scripts/hdmon.py apply --output "$RIG_MON_NAME" --scale 1.25 --timeout 90 >/dev/null
sleep 2
[ "$(scale)" = "1.25" ] || bad "P3: the change never landed"
pgrep -f "hdmon[.]py watch" >/dev/null || bad "P3: no watcher was started -- there is nothing to kill"
pkill -f "hdmon[.]py watch"
sleep 1
pgrep -f "hdmon[.]py watch" >/dev/null && bad "P3: the watcher survived being killed"
echo "    watcher killed, countdown still open"
sleep 4
S4=$(scale); echo "    scale with nobody watching: $S4"
[ "$S4" = "1.25" ] || bad "P3: something reverted it without a watcher -- the arm is not measuring what it says"
[ -e "$PENDING" ] || bad "P3: the pending record is gone, so the next start has nothing to act on"

echo "    --- next launch: hyprdrive-settings runs 'hdmon check' before it draws"
python3 scripts/hdmon.py check | sed 's/^/    /'
sleep 2
S5=$(scale); echo "    scale after the next start: $S5"
[ "$S5" = "$BASE" ] || bad "P3: the crash-safety restore did not happen (scale $S5)"
[ -e "$PENDING" ] && bad "P3: the pending record survived its own revert"

alive_or_die "the whole run"
echo
[ $FAIL = 0 ] && echo "X63 PASS -- expired, confirmed, and survived the app dying" || echo "X63 FAIL"
exit $FAIL
