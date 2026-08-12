#!/usr/bin/env bash
# x60_settings_schema -- the schema is a MIRROR, and a mirror is only worth
# having if something notices when it stops matching.
#
# docs/schema.json says which options the settings app can reach. 79 of them are
# Config.cpp's registrations, and Config.cpp is edited by people adding features,
# not by people thinking about the settings app. So the failure this gate stands
# over is not "the schema is wrong" -- it is "somebody added a key and nobody
# ever found out it was unreachable".
#
#   P1 COUNTS     the three sources are all present and the arithmetic adds up.
#                 79 plugin keys is the same number docs/CONFIG.md prints, from
#                 the same parser, so a drift between the two documents is not
#                 expressible any more.
#   P2 DRIFT      a key is ADDED to Config.cpp for real, and both checks must go
#                 red. This is the fail-on-old half of the pixel doctrine applied
#                 to a build check: a --check that has never been seen to fail is
#                 a --check nobody has tested.
#   P3 ROUTED     every plugin key reaches a pane that exists. An option the app
#                 cannot draw is worse than a missing one: the schema claims it.
#
# No compositor, no pixels, no fixtures. It is in the suite because it is part of
# `make all` and the suite is where a red thing gets seen.
set -u
cd "$(dirname "$0")/../../.."

OUT=/mnt/host/zrig/phase11/x60; mkdir -p "$OUT"
FAIL=0
bad() { echo "FAIL $*"; FAIL=1; }

echo "--- P1 COUNTS"
python3 scripts/gen_schema.py --check | tee "$OUT/counts.log" || bad "P1: docs/schema.json is stale in the tree as committed"
bash scripts/gen_keys_table.sh --check || bad "P1: docs/CONFIG.md is stale in the tree as committed"

read -r N_PLUGIN N_HYPR N_CURATED N_TOTAL N_PANES <<EOF
$(python3 -c "
import json
d=json.load(open('docs/schema.json'))['counts']
print(d['plugin'], d['hyprland'], d['curated'], d['total'], len(d['per_pane']))
")
EOF
echo "    plugin=$N_PLUGIN hyprland=$N_HYPR curated=$N_CURATED total=$N_TOTAL panes-with-rows=$N_PANES"

# The plugin count is the one number two documents have to agree on.
DOCROWS=$(grep -c '^| `' docs/CONFIG.md)
[ "$N_PLUGIN" = "$DOCROWS" ] || bad "P1: schema says $N_PLUGIN plugin keys, docs/CONFIG.md prints $DOCROWS"
[ "$N_PLUGIN" -ge 79 ] || bad "P1: only $N_PLUGIN plugin keys -- Config.cpp registers 79"
[ "$N_HYPR" -ge 300 ] || bad "P1: only $N_HYPR Hyprland options -- the descriptions snapshot looks truncated"
[ "$N_CURATED" -ge 10 ] || bad "P1: only $N_CURATED curated entries"
[ "$((N_PLUGIN + N_HYPR + N_CURATED))" = "$N_TOTAL" ] || bad "P1: the counts do not add up"

echo
echo "--- P2 DRIFT (a key really is added to Config.cpp, then taken back out)"
cp Config.cpp "$OUT/Config.cpp.bak"
restore() { cp "$OUT/Config.cpp.bak" Config.cpp; }
trap restore EXIT
LINE=$(grep -n 'makeShared<CBoolValue>(KEY("blur")' Config.cpp | head -1 | cut -d: -f1)
[ -n "$LINE" ] || { echo "FAIL P2: could not find an anchor registration to insert after"; exit 1; }
sed -i "${LINE}a\\    addKey(makeShared<CBoolValue>(KEY(\"x60_drift_probe\"), \"x60 drift probe -- the gate removes this\", false));" Config.cpp

if python3 scripts/gen_schema.py --check >"$OUT/drift-schema.log" 2>&1; then
    bad "P2: schema --check stayed GREEN with an extra key in Config.cpp -- the drift check is decorative"
else
    echo "    schema --check went red: $(grep -m1 'plugin' "$OUT/drift-schema.log" || true)"
    grep -q 'x60_drift_probe' "$OUT/drift-schema.log" \
        || bad "P2: the check failed but its diff does not name the new key"
fi
if bash scripts/gen_keys_table.sh --check >"$OUT/drift-doc.log" 2>&1; then
    bad "P2: docs/CONFIG.md --check stayed GREEN with an extra key in Config.cpp"
else
    echo "    docs/CONFIG.md --check went red too"
fi

restore
trap - EXIT
python3 scripts/gen_schema.py --check >/dev/null 2>&1 \
    || bad "P2: the tree did not come back green after the probe was removed"
bash scripts/gen_keys_table.sh --check >/dev/null 2>&1 \
    || bad "P2: docs/CONFIG.md did not come back green after the probe was removed"
echo "    both green again on revert"

echo
echo "--- P3 ROUTED"
python3 - <<'PY' || FAIL=1
import json, sys
d = json.load(open("docs/schema.json"))
panes = {p["id"] for p in d["panes"]}
bad = [e["key"] for e in d["entries"] if e["pane"] not in panes]
if bad:
    print("FAIL P3: %d entries route to a pane that does not exist: %s" % (len(bad), bad[:5]))
    sys.exit(1)
# Every pane the app draws must be reachable from the schema's own pane list.
missing = [p["id"] for p in d["panes"]
           if p["id"] != "monitors" and not any(e["pane"] == p["id"] for e in d["entries"])]
if missing:
    print("FAIL P3: panes with no rows at all: %s" % missing)
    sys.exit(1)
print("    %d entries, all routed, %d panes all populated (monitors is built from hyprctl)"
      % (len(d["entries"]), len(panes)))
PY

echo
[ $FAIL = 0 ] && echo "X60 PASS -- the mirror is current, and it has been seen to break" || echo "X60 FAIL"
exit $FAIL
