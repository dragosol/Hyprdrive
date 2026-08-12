#!/usr/bin/env bash
# x65_profile_roundtrip -- the undo button, and what happens when the app dies
# holding it.
#
# A profile system is easy to demonstrate and hard to believe. The demonstration
# is "it wrote a file and read it back"; the belief needs three things this gate
# measures instead of asserting:
#
#   P1 ROUND TRIP   a bulk apply across THREE different backends -- a compositor
#                   option, a plugin key and illogical-impulse's own config.json
#                   -- then revert, and grade it on BYTES (md5 of every file in
#                   the surface) AND on the live system (hyprctl getoption, ii's
#                   json). A revert that restores files but leaves the session on
#                   the old values is not a revert, and one that restores the
#                   session from a re-derivation rather than from the bytes is
#                   restoring what the code thinks it was.
#
#   P2 PROFILE      a named profile is applied over a changed surface and puts it
#                   back. Same grading. This is the "one click" half: `revert`
#                   with no argument, and `apply NAME`, are the same restore.
#
#   P3 CRASH        an apply is killed with os._exit AFTER the snapshot and after
#                   one value has landed -- the shape hdmon's countdown already
#                   proved is the one that matters. Nothing reverts it on its own
#                   (measured, by watching it stay wrong), and then `hdprof
#                   check` -- which the launcher runs before the window is drawn
#                   -- puts it back.
#
# WHY ii's config.json IS IN THE SURFACE, and why this gate insists on it. The
# settings app writes that file, and the WALLPAPER lives in it. A snapshot that
# skipped it would restore the accents without the picture they were derived
# from. It also costs the one expensive thing in this gate: restoring it restarts
# quickshell, so every phase asserts the shell came back -- a gate that left the
# desktop with no bar would poison every gate after it in the suite, and that
# exact failure was measured once during development (the restart inherited an
# environment with no WAYLAND_DISPLAY).
#
# NO PIXELS. Nothing here is a pixel claim: the artefacts are files and the
# compositor's own readback, both of which are exact. x61 already owns "the
# frost visibly changed", and duplicating a photograph here would add a flake
# without adding a claim.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=/mnt/host/zrig/phase12/x65; mkdir -p "$OUT"
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/hyprdrive
PENDING=$STATE/apply-pending.json
IICFG=$HOME/.config/illogical-impulse/config.json
FAIL=0
bad() { echo "FAIL $*"; FAIL=1; }

gate_slate x65_profile_roundtrip >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }

# ------------------------------------------------------------------ preflight --
for f in scripts/hdprof.py scripts/hdctl.py; do
    [ -f "$f" ] || { echo "FAIL preflight: this build has no $f -- there is no profile layer to test"; exit 1; }
done
command -v git >/dev/null || { echo "FAIL preflight: no git in this guest"; exit 1; }

manifest() { md5sum "$HOME"/.config/hypr/hyprdrive/*.lua "$IICFG" "$STATE/settings.json" 2>/dev/null; }
rounding() { hyprctl getoption decoration:rounding -j | python3 -c "import json,sys; print(json.load(sys.stdin)['int'])"; }
iconsize() { hyprctl getoption "$RIG_KEY:dock:icon_size" -j | python3 -c "import json,sys; print(json.load(sys.stdin)['int'])"; }
iiround()  { jq -r '.appearance.fakeScreenRounding' "$IICFG"; }
qs_alive() { pgrep -x qs >/dev/null; }

python3 scripts/hdprof.py init | sed 's/^/    /'
python3 scripts/hdprof.py snapshot --reason "x65 baseline" | sed 's/^/    /'
BASE_REF=$(python3 scripts/hdprof.py list -n 1 --json | python3 -c "import json,sys; print(json.load(sys.stdin)['head'])")
manifest > "$OUT/baseline.md5"
NFILES=$(wc -l < "$OUT/baseline.md5")
R0=$(rounding); I0=$(iconsize); Q0=$(iiround)
echo "preflight: baseline $BASE_REF over $NFILES files -- rounding=$R0 icon_size=$I0 ii.fakeScreenRounding=$Q0"
[ "$NFILES" -ge 10 ] || bad "preflight: only $NFILES files in the surface -- the app cannot have been installed"
qs_alive || bad "preflight: quickshell is not running, so the shell half of this gate proves nothing"

x65_cleanup() {
    python3 scripts/hdprof.py revert "$BASE_REF" >/dev/null 2>&1
    rm -f "$PENDING"
    git -C "$STATE/profiles" tag -d x65-profile >/dev/null 2>&1
    hyprctl reload >/dev/null 2>&1
}
trap x65_cleanup EXIT

# --------------------------------------------------------------- P1 ROUND TRIP --
echo
echo "--- P1 ROUND TRIP: three backends, one snapshot, one revert"
WANT_R=$((R0 + 7)); WANT_I=$((I0 + 7)); WANT_Q=$(( Q0 == 0 ? 1 : 0 ))
python3 scripts/hdctl.py bulk --reason "x65" \
    "decoration:rounding=$WANT_R" "$RIG_KEY:dock:icon_size=$WANT_I" \
    "ii:appearance.fakeScreenRounding=$WANT_Q" 2>&1 | sed 's/^/    /'
sleep 3
qs_alive || bad "P1: quickshell did not come back from the ii write"
R1=$(rounding); I1=$(iconsize); Q1=$(iiround)
echo "    live now: rounding=$R1 icon_size=$I1 ii.fakeScreenRounding=$Q1"
[ "$R1" = "$WANT_R" ] || bad "P1: the compositor did not take decoration:rounding ($R1)"
[ "$I1" = "$WANT_I" ] || bad "P1: the plugin did not take dock:icon_size ($I1)"
[ "$Q1" = "$WANT_Q" ] || bad "P1: ii's config.json does not carry the value ($Q1)"

DIRTY=$(python3 scripts/hdprof.py status --json | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['dirty']))")
echo "    hdprof sees $DIRTY changed files"
[ "$DIRTY" -ge 2 ] || bad "P1: the profile layer did not notice a three-backend write (dirty=$DIRTY)"

python3 scripts/hdprof.py revert 2>&1 | sed 's/^/    /'
sleep 3
qs_alive || bad "P1: quickshell did not come back from the revert"
R2=$(rounding); I2=$(iconsize); Q2=$(iiround)
echo "    live after revert: rounding=$R2 icon_size=$I2 ii.fakeScreenRounding=$Q2"
[ "$R2" = "$R0" ] || bad "P1: rounding came back as $R2, not $R0"
[ "$I2" = "$I0" ] || bad "P1: icon_size came back as $I2, not $I0"
[ "$Q2" = "$Q0" ] || bad "P1: ii's value came back as $Q2, not $Q0"

# The bytes, not a re-derivation of the bytes.
if md5sum -c --quiet "$OUT/baseline.md5" > "$OUT/p1-md5.log" 2>&1; then
    echo "    all $NFILES files are byte-identical to the baseline"
else
    bad "P1: $(grep -c FAILED "$OUT/p1-md5.log") files came back different"
    sed 's/^/      /' "$OUT/p1-md5.log" | head -8
fi
CLEAN=$(python3 scripts/hdprof.py status --json | python3 -c "import json,sys; print(len(json.load(sys.stdin)['dirty']))")
[ "$CLEAN" = 0 ] || bad "P1: the surface is still dirty after a revert ($CLEAN files)"

# ------------------------------------------------------------------ P2 PROFILE --
echo
echo "--- P2 PROFILE: a name on a snapshot, applied over a changed surface"
python3 scripts/hdprof.py save x65-profile 2>&1 | sed 's/^/    /'
python3 scripts/hdprof.py profiles | sed 's/^/    /'
python3 scripts/hdprof.py profiles --json | grep -q x65-profile || bad "P2: the profile is not in the list"

python3 scripts/hdctl.py set decoration:rounding "$WANT_R" >/dev/null 2>&1
sleep 2
[ "$(rounding)" = "$WANT_R" ] || bad "P2: the change never landed, so the restore proves nothing"
python3 scripts/hdprof.py apply x65-profile 2>&1 | sed 's/^/    /'
sleep 3
R3=$(rounding)
echo "    live after applying the profile: rounding=$R3"
[ "$R3" = "$R0" ] || bad "P2: applying the profile left rounding at $R3"
md5sum -c --quiet "$OUT/baseline.md5" >/dev/null 2>&1 \
    && echo "    files byte-identical to the profile's state" \
    || bad "P2: the profile did not restore the files"

# -------------------------------------------------------------------- P3 CRASH --
echo
echo "--- P3 CRASH: the apply dies after the snapshot and after one write"
[ -e "$PENDING" ] && bad "P3: a pending record existed before the arm started"
python3 - <<'PY' 2>&1 | sed 's/^/    /'
import os, sys
sys.path.insert(0, "scripts")
import hdprof, hdctl
ref = hdprof.snapshot_before("x65: an apply that is about to die")
sch = hdctl.schema()
cur = hdctl.getoption("decoration:rounding")
hdctl.set_one(sch, "decoration:rounding", str(int(cur) + 9))
print("snapshot %s taken, one value written, now dying without finish()" % ref)
sys.stdout.flush()
os._exit(9)
PY
hyprctl reload >/dev/null 2>&1
sleep 2
R4=$(rounding)
echo "    pending record: $([ -e "$PENDING" ] && echo present || echo MISSING)"
echo "    live rounding after the death: $R4"
[ -e "$PENDING" ] || bad "P3: no pending record, so the next start has nothing to act on"
[ "$R4" = "$((R0 + 9))" ] || bad "P3: the half-apply never landed ($R4) -- there is nothing to recover from"

# Nobody is watching. Proved by watching.
sleep 4
[ "$(rounding)" = "$R4" ] || bad "P3: something put it back on its own -- this arm is not measuring what it says"
echo "    still wrong after 4s with nobody watching, as it should be"

echo "    --- next launch: hyprdrive-settings runs 'hdprof check' before it draws"
python3 scripts/hdprof.py check 2>&1 | sed 's/^/    /'
sleep 3
R5=$(rounding)
echo "    live rounding after the next start: $R5"
[ "$R5" = "$R0" ] || bad "P3: the crash-safety restore did not happen (rounding $R5)"
[ -e "$PENDING" ] && bad "P3: the pending record survived its own restore"
md5sum -c --quiet "$OUT/baseline.md5" >/dev/null 2>&1 \
    && echo "    files byte-identical again" \
    || bad "P3: the restore did not put the bytes back"
qs_alive || bad "P3: quickshell is gone at the end of the run"

alive_or_die "the whole run"
echo
[ $FAIL = 0 ] && echo "X65 PASS -- three backends round-tripped byte for byte, a named profile restored, and an apply that died was undone by the next start" || echo "X65 FAIL"
exit $FAIL
