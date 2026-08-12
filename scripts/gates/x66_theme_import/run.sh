#!/usr/bin/env bash
# x66_theme_import -- a theme file goes in, and everything it said is accounted
# for: mapped, refused, or kept exactly as written.
#
# THE PREDICTION IS WRITTEN IN THIS FILE, not read out of the importer. A gate
# that asked the parser what it parsed and then agreed with it would pass on any
# parser. So the expected key set, the expected values and the expected leftover
# LINE NUMBERS are hardcoded here against two fixtures that live in the repo; if
# somebody edits a fixture, this gate goes red, which is the correct outcome.
#
#   P1 PREVIEW    dockward.conf: exactly nine schema keys, with the values the
#                 file asks for, one of them flagged LOCKED, and exactly one line
#                 that is not a setting.
#   P2 APPLY      the values are live, the locked one was REFUSED (not applied,
#                 not silently dropped), the leftover is in the raw block, the
#                 fragment still parses as Lua, and a snapshot exists that names
#                 the import.
#   P3 VERBATIM   awkward.conf: six leftovers, byte-identical to the fixture's
#                 own lines including leading whitespace; the `]]` payload did
#                 not close the Lua long string (the bracket level went to `[=[`);
#                 and the FIRST import's block is still there, because the raw
#                 block is user-owned and an import appends to it.
#   P4 REVERT     `hdprof revert` with no argument undoes the last import and
#                 leaves the first one standing -- the undo stack, one step --
#                 and then a revert to the gate's own baseline puts every file
#                 back byte for byte.
#
# `luac -p` is the check that matters most and is the cheapest: the leftovers are
# hyprlang and the fragment is Lua, so the whole verbatim mechanism is one
# quoting mistake away from a config that does not parse -- which in this system
# is a session that does not start.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=/mnt/host/zrig/phase12/x66; mkdir -p "$OUT"
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/hyprdrive
FRAG=$HOME/.config/hypr/hyprdrive/40-hyprland.lua
DOCKWARD=scripts/fixtures/themes/dockward.conf
AWKWARD=scripts/fixtures/themes/awkward.conf
FAIL=0
bad() { echo "FAIL $*"; FAIL=1; }

gate_slate x66_theme_import >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }

# ------------------------------------------------------------------ preflight --
for f in scripts/hdimport.py scripts/hdprof.py "$DOCKWARD" "$AWKWARD"; do
    [ -f "$f" ] || { echo "FAIL preflight: this build has no $f -- there is no theme importer to test"; exit 1; }
done
command -v luac >/dev/null || { echo "FAIL preflight: no luac in this guest -- the Lua syntax check is the point"; exit 1; }

manifest() { md5sum "$HOME"/.config/hypr/hyprdrive/*.lua "$STATE/settings.json" 2>/dev/null; }
opt() { hyprctl getoption "$1" -j | python3 -c "import json,sys; d=json.load(sys.stdin); print(next(v for k,v in d.items() if k!='option' and k!='set'))"; }

python3 scripts/hdprof.py init >/dev/null 2>&1
python3 scripts/hdprof.py snapshot --reason "x66 baseline" | sed 's/^/    /'
BASE_REF=$(python3 scripts/hdprof.py list -n 1 --json | python3 -c "import json,sys; print(json.load(sys.stdin)['head'])")
manifest > "$OUT/baseline.md5"
BASE_ROUNDING=$(opt decoration:rounding)
BASE_BLUR=$(opt decoration:blur:enabled)
echo "preflight: baseline $BASE_REF -- rounding=$BASE_ROUNDING blur:enabled=$BASE_BLUR"
[ "$BASE_BLUR" = True ] || bad "preflight: blur is already off, so 'the locked key was refused' cannot be measured"

x66_cleanup() {
    python3 scripts/hdprof.py revert "$BASE_REF" >/dev/null 2>&1
    rm -f "$STATE/apply-pending.json"
    hyprctl reload >/dev/null 2>&1
}
trap x66_cleanup EXIT

# ------------------------------------------------------------------ P1 PREVIEW --
echo
echo "--- P1 PREVIEW: the prediction is in the gate, not in the parser"
python3 scripts/hdimport.py preview "$DOCKWARD" --json > "$OUT/dockward-preview.json"
python3 scripts/hdimport.py preview "$DOCKWARD" > "$OUT/dockward-preview.txt"
sed 's/^/    /' "$OUT/dockward-preview.txt" | head -24

python3 - "$OUT/dockward-preview.json" <<'PY' || FAIL=1
import json, sys

r = json.load(open(sys.argv[1]))
# Every key dockward.conf names that this schema has a row for, and the value it
# asks for. Written by hand off the fixture; the parser gets no say.
want = {
    "decoration:rounding": "8",
    "decoration:blur:size": "4",
    "decoration:blur:passes": "2",
    "decoration:blur:enabled": "false",
    "decoration:blur:vibrancy_darkness": "0.55",
    "plugin:hyprdrive:dock:icon_size": "56",
    "plugin:hyprdrive:dock:corner_radius": "22",
    "plugin:hyprdrive:dock:autohide": "false",
    "plugin:hyprdrive:col_highlight": "rgba(d08770ff)",
}
got = {m["key"]: m["new"] for m in r["mapped"] + r["unchanged"]}
bad = 0
missing = set(want) - set(got)
extra = set(got) - set(want)
if missing:
    print("  FAIL the preview did not map: %s" % ", ".join(sorted(missing))); bad = 1
if extra:
    print("  FAIL the preview mapped keys the fixture does not name: %s" % ", ".join(sorted(extra))); bad = 1
for k, v in sorted(want.items()):
    if k in got and got[k] != v:
        print("  FAIL %s: preview says %r, the file says %r" % (k, got[k], v)); bad = 1
if not bad:
    print("  ok   all %d schema keys mapped with the values the file asks for" % len(want))

# The nested plugin block is the one that would need a special case if the
# category stack were not doing the work. Say so out loud.
if "plugin:hyprdrive:dock:icon_size" in got:
    print("  ok   plugin { hyprdrive { dock { icon_size } } } -> plugin:hyprdrive:dock:icon_size")

locked = [m for m in r["mapped"] if m["key"] == "decoration:blur:enabled" and m["locked"]]
print("  %s decoration:blur:enabled is flagged LOCKED in the preview"
      % ("ok  " if locked else "FAIL"))
bad = bad or not locked

v = [x["text"] for x in r["verbatim"]]
if v == ["exec-once = hyprpaper"]:
    print("  ok   exactly one line is not a setting, and it is the exec-once")
else:
    print("  FAIL verbatim is %r, wanted ['exec-once = hyprpaper']" % v); bad = 1

sys.exit(bad)
PY

# -------------------------------------------------------------------- P2 APPLY --
echo
echo "--- P2 APPLY"
SNAPS_BEFORE=$(python3 scripts/hdprof.py list -n 50 --json | python3 -c "import json,sys; print(len(json.load(sys.stdin)['snapshots']))")
python3 scripts/hdimport.py apply "$DOCKWARD" > "$OUT/dockward-apply.log" 2>&1
sed 's/^/    /' "$OUT/dockward-apply.log"
sleep 3

for pair in "decoration:rounding 8" "decoration:blur:size 4" "$RIG_KEY:dock:icon_size 56" "$RIG_KEY:dock:corner_radius 22"; do
    set -- $pair
    GOT=$(opt "$1")
    printf '    %-42s = %-8s want %s\n' "$1" "$GOT" "$2"
    [ "$GOT" = "$2" ] || bad "P2: $1 is $GOT, the theme asked for $2"
done
NOWBLUR=$(opt decoration:blur:enabled)
echo "    decoration:blur:enabled = $NOWBLUR (the theme asked for false; the schema locks it)"
[ "$NOWBLUR" = True ] || bad "P2: the LOCKED key was applied -- an import walked past the frost rule"

python3 scripts/hdctl.py raw hyprland > "$OUT/raw-after-dockward.txt"
grep -qx "exec-once = hyprpaper" "$OUT/raw-after-dockward.txt" \
    && echo "    the leftover is in the raw block, on its own line, unchanged" \
    || bad "P2: the leftover line is not in the raw block"
grep -q "imported verbatim from dockward.conf" "$OUT/raw-after-dockward.txt" \
    || bad "P2: the block does not say where it came from"

luac -p "$FRAG" && echo "    $FRAG still parses as Lua" || bad "P2: the fragment does not parse -- this would not boot"

# The restore point, taken from what the importer SAID it took. A snapshot is
# only a new commit when the surface has actually moved -- this gate's own
# baseline is often still HEAD -- so the claim worth checking is not "a commit
# appeared" but "HEAD is the state this import can be undone to". P3 checks the
# commit half, where the surface genuinely has moved.
IMPORT_REF=$(sed -n 's/^hdimport: snapshot \([0-9a-f]*\) taken.*/\1/p' "$OUT/dockward-apply.log")
HEAD_REF=$(python3 scripts/hdprof.py list -n 1 --json | python3 -c "import json,sys; print(json.load(sys.stdin)['head'])")
echo "    the import says it can be undone to $IMPORT_REF; HEAD is $HEAD_REF"
[ -n "$IMPORT_REF" ] || bad "P2: the import did not report taking a snapshot at all"
[ "$IMPORT_REF" = "$HEAD_REF" ] || bad "P2: HEAD ($HEAD_REF) is not the state the import can be undone to ($IMPORT_REF)"
[ -e "$STATE/apply-pending.json" ] && bad "P2: the import left its crash-safety record behind"

# ----------------------------------------------------------------- P3 VERBATIM --
echo
echo "--- P3 VERBATIM: awkward.conf, byte for byte"
python3 scripts/hdimport.py apply "$AWKWARD" 2>&1 | sed 's/^/    /'
sleep 3
# The surface HAS moved this time -- dockward changed four files -- so the
# snapshot is a real commit and the log has to name it.
SNAPS_AFTER=$(python3 scripts/hdprof.py list -n 50 --json | python3 -c "import json,sys; print(len(json.load(sys.stdin)['snapshots']))")
python3 scripts/hdprof.py list -n 3 | sed 's/^/    /'
[ "$SNAPS_AFTER" -gt "$SNAPS_BEFORE" ] || bad "P3: no snapshot was committed across two imports ($SNAPS_BEFORE -> $SNAPS_AFTER)"
python3 scripts/hdprof.py list -n 3 --json | grep -q "theme import: awkward.conf" \
    || bad "P3: no snapshot names the import"
[ -e "$STATE/apply-pending.json" ] && bad "P3: the import left its crash-safety record behind"
python3 scripts/hdctl.py raw hyprland > "$OUT/raw-after-awkward.txt"

# What the fixture's own leftover lines ARE -- taken from the fixture by line
# number, so this compares the raw block against the file rather than against a
# transcription of it. Leading whitespace included on purpose: line 25 is
# indented inside a category and verbatim means verbatim.
sed -n '10p;12p;25p;36p;37p;38p' "$AWKWARD" > "$OUT/expected-verbatim.txt"
awk '/^hyprdrive_import_verbatim = \[=\[$/{f=1;next} /^\]=\]$/{f=0} f' \
    "$OUT/raw-after-awkward.txt" > "$OUT/got-verbatim.txt"
if diff -u "$OUT/expected-verbatim.txt" "$OUT/got-verbatim.txt" > "$OUT/verbatim.diff"; then
    echo "    all $(wc -l < "$OUT/expected-verbatim.txt") leftover lines are byte-identical to the fixture"
    sed 's/^/      | /' "$OUT/got-verbatim.txt"
else
    bad "P3: the verbatim block is not what the file said"
    sed 's/^/      /' "$OUT/verbatim.diff" | head -20
fi

grep -q 'closes \]\] a long string' "$OUT/got-verbatim.txt" \
    && echo "    the ']]' payload survived -- the bracket level went to [=[" \
    || bad "P3: the ']]' line is missing, which is what a swallowed long string looks like"

grep -qx "exec-once = hyprpaper" "$OUT/raw-after-awkward.txt" \
    && echo "    dockward.conf's block is still there -- the import APPENDED to the raw block" \
    || bad "P3: the second import ate the first one's block"

luac -p "$FRAG" && echo "    the fragment with both blocks still parses as Lua" \
    || bad "P3: the fragment does not parse after the awkward import"

[ "$(opt decoration:rounding)" = 6 ] || bad "P3: awkward's own values did not land (rounding $(opt decoration:rounding))"

# ------------------------------------------------------------------- P4 REVERT --
echo
echo "--- P4 REVERT: one step of the undo stack, then all the way back"
python3 scripts/hdprof.py revert 2>&1 | sed 's/^/    /'
sleep 3
R=$(opt decoration:rounding)
echo "    rounding after undoing the awkward import: $R (dockward asked for 8)"
[ "$R" = 8 ] || bad "P4: one revert did not land on the state before the last import"
python3 scripts/hdctl.py raw hyprland > "$OUT/raw-after-revert.txt"
grep -q "awkward.conf" "$OUT/raw-after-revert.txt" && bad "P4: the awkward block survived its own undo"
grep -qx "exec-once = hyprpaper" "$OUT/raw-after-revert.txt" \
    && echo "    dockward's block is still there: the undo went back one step, not to zero" \
    || bad "P4: undoing the second import took the first one with it"

python3 scripts/hdprof.py revert "$BASE_REF" 2>&1 | sed 's/^/    /'
sleep 3
echo "    rounding back at the baseline: $(opt decoration:rounding) (was $BASE_ROUNDING)"
[ "$(opt decoration:rounding)" = "$BASE_ROUNDING" ] || bad "P4: the baseline revert did not restore the value"
RAW=$(python3 scripts/hdctl.py raw hyprland | tr -d '[:space:]')
[ -z "$RAW" ] || bad "P4: the raw block is not empty again"
if md5sum -c --quiet "$OUT/baseline.md5" > "$OUT/p4-md5.log" 2>&1; then
    echo "    every fragment is byte-identical to the baseline"
else
    bad "P4: $(grep -c FAILED "$OUT/p4-md5.log") files differ from the baseline"
    sed 's/^/      /' "$OUT/p4-md5.log" | head -8
fi

alive_or_die "the whole run"
echo
[ $FAIL = 0 ] && echo "X66 PASS -- nine keys mapped as predicted, the locked one refused, twelve leftovers kept byte for byte in Lua that parses, and both imports undone" || echo "X66 FAIL"
exit $FAIL
