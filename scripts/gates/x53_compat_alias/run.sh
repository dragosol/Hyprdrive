#!/usr/bin/env bash
# x53_compat_alias -- the pre-rename names still work, and say so once.
#
# Phase 9 renamed every user-facing surface of this plugin from `scrolloverview`
# to `hyprdrive`. The promise attached to that rename is that an existing config
# keeps working for one release. This gate is that promise, asserted:
#
#   A  a value set under the OLD key prefix is readable under the NEW one, for
#      every type the copy has an arm for -- int, float, string, bool, colour.
#      Set through a real config fragment and a real `hyprctl reload`, not a
#      runtime write: the adoption runs on the config-reloaded event, and a
#      runtime hl.config that never reloads would prove a path no user takes.
#      Every probe key is checked to be UNSET first: if the running config also
#      sets the modern name, the new name wins by design and the copy is
#      correctly skipped -- which would make this phase pass for the wrong
#      reason. (Found the hard way: the first cut probed `workspace_gap`, which
#      this rice's own 20-layout.lua sets.)
#   A' the precedence rule itself: a key set under BOTH names keeps the value
#      the NEW name gives it. This is the only arm that covers the gradient
#      pair, because both gradient keys are set by the rice and there is no
#      unset one to copy into.
#   B  a dispatch through the OLD Lua namespace reaches the same handler, proven
#      by STATE (the window lands on special:minimized) rather than by pixels:
#      "the old name still dispatches" is a fact about the handler, and a
#      screenshot would only be a slower way of asking.
#   C  exactly ONE deprecation warning for the whole session, however many old
#      names were used, and across at least two DIFFERENT legacy surfaces. A
#      warning per use is a warning nobody reads, and this one fires on every
#      config reload and every keypress.
#
# This is the ONE gate that must NOT route the old name through $RIG_NS. Every
# other gate asks about the plugin; this one asks about the rename, so it spells
# both names out on purpose.
#
# On a pre-rename build there is no compat log, no hyprdrive namespace and no
# hyprdrive key, and the gate stops at its first line -- which is the only
# reason its pass means anything (measured: zrig/phase9/x53-on-parent.log).
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

LOG=/tmp/hyprdrive-compat.log
FRAG=$HOME/.config/hypr/hyprdrive/99-compat-probe.lua
OUT=/mnt/host/zrig/phase9/x53; mkdir -p $OUT
FAIL=0
say() { echo "$@"; }
bad() { echo "FAIL $*"; FAIL=1; }
opt() { hyprctl getoption "$1" | head -1 | awk '{print $2}'; }
# Gradients print `gradient data: <hex> <angle>deg`, so field 2 is the word
# "data:". Everything after the first colon is the value, for every type.
optg() { hyprctl getoption "$1" | head -1 | cut -d: -f2- | xargs; }
setby() { hyprctl getoption "$1" | sed -n 2p | awk '{print $2}'; }

cleanup() { rm -f "$FRAG"; hyprctl reload >/dev/null 2>&1; }
trap cleanup EXIT

# A clean slate first. This gate opens the overview, spawns a fixture and
# reloads the config three times; run back to back with anything else it would
# otherwise inherit whatever the previous run left focused. suite.sh slates
# before every gate anyway, so this only matters for a standalone run.
gate_slate x53_compat_alias >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }

# ------------------------------------------------------------------ preflight --
[ -f "$LOG" ] || { bad "no $LOG -- this build has no compat layer"; exit 1; }
hyprctl getoption "$RIG_KEY:mission_control_gap" 2>/dev/null | grep -q '^int' \
    || { bad "$RIG_KEY:mission_control_gap does not exist -- no hyprdrive key namespace"; exit 1; }

W0=$(grep -c '^WARN ' "$LOG" || true)
U0=$(grep -c '^use '  "$LOG" || true)
say "=== preflight: $W0 warnings and $U0 uses already recorded this session"

# ------------------------------------------------- A: the old keys read through --
# One key per arm of the copy in Compat.cpp, pipe-separated because the keys
# themselves contain colons:   key | expected readback | which arm
PROBES='mission_control_gap|77|int
dock:icon_size|33|int
dock:background_opacity|0.770000|float
terminal|probeterm|string
mission_control|false|bool
dock:indicator_color|4278255360|colour'

say "=== A control: every probe key must be UNSET under both names first"
while IFS='|' read -r K WANT KIND; do
    S=$(setby "$RIG_KEY:$K")
    say "A control: $RIG_KEY:$K set=$S value=$(opt "$RIG_KEY:$K")"
    [ "$S" = "false" ] || bad "A control: $RIG_KEY:$K is already set by this config -- the copy would be skipped by the precedence rule and A would pass for free"
done <<< "$PROBES"
[ $FAIL = 0 ] || { echo "X53 FAIL (preconditions)"; exit 1; }

mkdir -p "$(dirname "$FRAG")"
cat > "$FRAG" <<'LUA'
-- x53_compat_alias probe. Deliberately the PRE-RENAME spelling: this fragment
-- exists to be adopted onto the hyprdrive keys. Removed by the gate's EXIT trap.
if hyprdrive_loaded() then
    hl.config({ plugin = { scrolloverview = {
        mission_control_gap = 77,
        mission_control     = false,
        terminal            = "probeterm",
        col_highlight       = 0xff123456,   -- A': also set under the NEW name by the rice
        dock = {
            icon_size          = 33,
            background_opacity = 0.77,
            indicator_color    = 0xff00ff00,
        },
    } } })
end
LUA
HL0=$(optg "$RIG_KEY:col_highlight")
hyprctl reload >/dev/null 2>&1; sleep 2.5

say "=== A: what the new names read after the reload"
while IFS='|' read -r K WANT KIND; do
    GOT=$(opt "$RIG_KEY:$K"); LEG=$(opt "plugin:scrolloverview:$K")
    say "A $KIND $K: legacy=$LEG new=$GOT (wanted $WANT)"
    [ "$LEG" = "$WANT" ] || bad "A: the legacy $K did not take the value at all"
    [ "$GOT" = "$WANT" ] || bad "A: $K did not reach the new key ($KIND arm of the copy)"
done <<< "$PROBES"

HL1=$(optg "$RIG_KEY:col_highlight")
say "=== A' precedence: col_highlight is set under BOTH names; new must win"
say "A': col_highlight was $HL0, is $HL1 with the legacy probe live"
[ "$HL1" = "$HL0" ] || bad "A': the deprecated name overrode the new one"

rm -f "$FRAG"
hyprctl reload >/dev/null 2>&1; sleep 2.5
BACK=$(opt "$RIG_KEY:mission_control_gap")
say "A restore: $RIG_KEY:mission_control_gap is $BACK with the probe removed"
[ "$BACK" = "77" ] && bad "A restore: the adopted value outlived the config that set it"

# --------------------------------------------- B: the old Lua namespace works --
say "=== B: hl.plugin.scrolloverview.* still dispatches"
killothers X53FIX
fixture_kitty X53FIX 600 300 800 500 "#103018" || { bad "B: no fixture"; exit 1; }
ADDR=$(hyprctl clients -j | python3 -c "
import json,sys
print(next((c['address'] for c in json.load(sys.stdin) if c['class']=='X53FIX'), ''))")
[ -n "$ADDR" ] || { bad "B: fixture has no address"; exit 1; }
ws() { hyprctl clients -j | python3 -c "
import json,sys
print(next((c['workspace']['name'] for c in json.load(sys.stdin) if c['address']=='$ADDR'), 'gone'))"; }

WS0=$(ws); say "B: fixture starts on $WS0"
[ "$WS0" = "special:minimized" ] && bad "B control: the fixture was already minimized"

cfg_dock "minimize_ms=0"; sleep 0.4
dsp "hl.plugin.scrolloverview.overview([[on]])"; sleep 2.0
dsp "hl.plugin.scrolloverview.minimize([[window]])"; sleep 1.5
WS1=$(ws); say "B: after the OLD name's minimize the fixture is on $WS1 (wanted special:minimized)"
[ "$WS1" = "special:minimized" ] || bad "B: the old Lua namespace did not dispatch"

dsp "hl.plugin.$RIG_NS.minimize([[restore]])"; sleep 1.5
WS2=$(ws); say "B: after the NEW name's restore the fixture is on $WS2 (wanted $WS0)"
[ "$WS2" = "$WS0" ] || bad "B: the new name did not undo what the old one did"
ov_off_settled
alive_or_die "after the alias dispatches"

# ------------------------------------------------------- C: warned exactly once --
W1=$(grep -c '^WARN ' "$LOG" || true)
U1=$(grep -c '^use '  "$LOG" || true)
KEYUSE=$(grep -c '^use key ' "$LOG" || true)
LUAUSE=$(grep -c '^use lua ' "$LOG" || true)
say "=== C: $U1 uses ($KEYUSE key, $LUAUSE lua), $W1 warnings"
[ "$W1" = "1" ]     || bad "C: $W1 deprecation warnings, wanted exactly 1"
[ "$U1" -ge 2 ]     || bad "C: only $U1 legacy uses recorded, wanted at least 2"
[ "$KEYUSE" -ge 1 ] || bad "C: no legacy CONFIG KEY use recorded"
[ "$LUAUSE" -ge 1 ] || bad "C: no legacy LUA namespace use recorded"
[ "$U1" -gt "$W1" ] || bad "C: uses ($U1) did not outnumber warnings ($W1) -- once-per-session is unproven"

cp "$LOG" $OUT/compat.log 2>/dev/null || true
grep '^WARN ' "$LOG" | sed 's/^/  /'

echo
[ $FAIL = 0 ] && echo "X53 PASS -- old keys adopt across every type, the new name wins ties, the old namespace dispatches, one warning" \
              || echo "X53 FAIL"
exit $FAIL
