#!/usr/bin/env bash
# x62_raw_and_pin -- the two escape hatches, driven through the app's own writer.
#
# Both of these are the same idea seen twice: the fragment layer's ordering is
# what makes a hand-written line and a pinned value win, and NOTHING has to
# cooperate for that -- not theme-sync, not the app, not the plugin. So the way
# to test them is to regenerate everything underneath and check they are still
# standing.
#
#   P1 RAW SURVIVES   type a line into the Blur pane's raw block, then make the
#                     app rewrite that fragment's machine half AND make
#                     theme-sync regenerate the derived fragment (which is what a
#                     wallpaper change does). The line is still there and still
#                     in effect.
#   P2 RAW FANS OUT   the line was decoration:blur:* -- so the DOCK's frost moved
#                     too, without the line naming the dock. dock:blur_* are all
#                     -1 = "follow decoration:blur:*", and this is the check that
#                     that inheritance is real rather than documented.
#   P3 PIN            pin a theme-derived dock accent from the app (`hdctl set`
#                     on a derived key IS the pin -- every pane fragment sorts
#                     after 05-theme-derived.lua). theme-sync must then report it
#                     masked and stop emitting it, while the unpinned accent
#                     keeps following. Unpin, and it follows again.
#
# P3 is z10's claim reached from the other end. z10 swaps the wallpaper and
# photographs the dock; it needs an opaque backdrop fixture and four minutes to
# do it. This gate does not re-photograph what z10 already grades -- it proves
# the APP's write produces the pin z10 grades, by running theme-sync itself (the
# same call the path unit makes on a palette change) and reading what it emits.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=/mnt/host/zrig/phase11/x62; mkdir -p "$OUT"
FRAGDIR=$HOME/.config/hypr/hyprdrive
DERIVED=$FRAGDIR/05-theme-derived.lua
RAWLINE='hl.config({ decoration = { blur = { noise = 0.37 } } })'
FAIL=0
bad() { echo "FAIL $*"; FAIL=1; }

gate_slate x62_raw_and_pin >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }

x62_restore() {
    : | python3 scripts/hdctl.py raw-write blur --no-apply >/dev/null 2>&1
    python3 scripts/hdctl.py unset plugin:hyprdrive:dock:indicator_color --no-apply >/dev/null 2>&1
    python3 scripts/hdctl.py unset decoration:blur:size --no-apply >/dev/null 2>&1
    python3 scripts/theme-sync.py --no-apply >/dev/null 2>&1
    hyprctl reload >/dev/null 2>&1
}
trap x62_restore EXIT
x62_restore     # start from a known-clean raw block and no pins

# ---------------------------------------------------------------- P1 RAW --
echo "--- P1 RAW SURVIVES"
BASE_NOISE=$(hyprctl getoption decoration:blur:noise -j | python3 -c "import json,sys; print(json.load(sys.stdin)['float'])")
echo "    decoration:blur:noise starts at $BASE_NOISE"

printf '%s\n' "-- x62: typed by hand into the Blur pane's raw editor" "$RAWLINE" \
    | python3 scripts/hdctl.py raw-write blur | sed 's/^/    /'
sleep 2
GOT=$(hyprctl getoption decoration:blur:noise -j | python3 -c "import json,sys; print(json.load(sys.stdin)['float'])")
echo "    after the raw write, noise = $GOT"
python3 -c "import sys; sys.exit(0 if abs($GOT-0.37) < 0.005 else 1)" \
    || bad "P1: the raw line did not take effect"

# Now make everything under it regenerate. Two different writers, because they
# are the two that exist: the app rewriting the pane's machine half, and
# theme-sync rewriting the derived fragment (what a wallpaper change triggers).
python3 scripts/hdctl.py set decoration:blur:size 9 --no-apply | sed 's/^/    /'
python3 scripts/theme-sync.py --no-apply | sed 's/^/    /'
hyprctl reload >/dev/null; sleep 2

python3 scripts/hdctl.py raw blur > "$OUT/raw-after.txt"
grep -qF "$RAWLINE" "$OUT/raw-after.txt" \
    && echo "    the raw block survived both regenerations, byte for byte" \
    || bad "P1: the raw line is gone after a regeneration"
GOT2=$(hyprctl getoption decoration:blur:noise -j | python3 -c "import json,sys; print(json.load(sys.stdin)['float'])")
echo "    and is still in effect: noise = $GOT2"
python3 -c "import sys; sys.exit(0 if abs($GOT2-0.37) < 0.005 else 1)" \
    || bad "P1: the raw line survived as text but stopped applying"
# and the machine half really was rewritten underneath it
grep -q "size = 9" "$FRAGDIR/41-blur.lua" || bad "P1: the machine half was not rewritten, so nothing was survived"

# --------------------------------------------------------------- P2 FANOUT --
echo
echo "--- P2 RAW FANS OUT (nothing in that line mentions the dock)"
for k in blur_size blur_passes blur_noise blur_contrast blur_vibrancy blur_brightness; do
    v=$(hyprctl getoption plugin:hyprdrive:dock:$k -j | python3 -c "
import json,sys
d=json.load(sys.stdin); print(d.get('int', d.get('float')))")
    case "$v" in
        -1|-1.0) ;;
        *) bad "P2: dock:$k is $v, not -1 -- this dock is NOT following decoration:blur:*, so a raw line there reaches it by luck" ;;
    esac
done
echo "    all six dock blur keys are -1 = follow decoration:blur:*"
echo "    so noise=0.37 is the dock pill's grain, the strip cells' grain and the"
echo "    overview panels' grain, from one line that names none of them"
grep -q 'live_layer_frost' docs/schema.json || bad "P2: live_layer_frost is not in the schema"

# ------------------------------------------------------------------ P3 PIN --
echo
echo "--- P3 PIN (a pin is the app writing a derived key -- there is no second mechanism)"
python3 scripts/theme-sync.py --no-apply >/dev/null
DERIVED_BEFORE=$(grep -c 'indicator_color' "$DERIVED" || true)
grep -q 'indicator_color *= *0x' "$DERIVED" \
    && echo "    unpinned: 05-theme-derived.lua emits indicator_color" \
    || bad "P3: the derived fragment is not emitting indicator_color to begin with"

python3 scripts/hdctl.py set plugin:hyprdrive:dock:indicator_color 0xFF00FF00 | sed 's/^/    /'
sleep 1.5
PINNED=$(hyprctl getoption plugin:hyprdrive:dock:indicator_color -j | python3 -c "import json,sys; print(json.load(sys.stdin)['int'])")
echo "    compositor reports indicator_color = $PINNED (want 4278255360 = 0xFF00FF00)"
[ "$PINNED" = "4278255360" ] || bad "P3: the pin did not reach the compositor"

# The wallpaper-change path, run by hand: this is exactly what the systemd path
# unit fires when matugen rewrites the palette.
python3 scripts/theme-sync.py --no-apply > "$OUT/theme-sync-pinned.log"
sed 's/^/    /' "$OUT/theme-sync-pinned.log"
grep -q 'masked=.*indicator_color' "$OUT/theme-sync-pinned.log" \
    || bad "P3: theme-sync did not report the app's write as a pin"
grep -q 'PINNED in 42-dock.lua' "$DERIVED" \
    || bad "P3: the derived fragment still emits indicator_color -- it did not stand down"
grep -q 'col_highlight *= *"rgba' "$DERIVED" \
    && echo "    and the UNPINNED accent (col_highlight) is still being derived" \
    || bad "P3: the unpinned accent stopped being derived too -- the mask is too wide"

hyprctl reload >/dev/null; sleep 2
STILL=$(hyprctl getoption plugin:hyprdrive:dock:indicator_color -j | python3 -c "import json,sys; print(json.load(sys.stdin)['int'])")
[ "$STILL" = "4278255360" ] || bad "P3: the pin did not survive a reload (got $STILL)"
echo "    the pin survives the reload theme-sync applies with"

echo
echo "    --- unpin"
python3 scripts/hdctl.py unset plugin:hyprdrive:dock:indicator_color | sed 's/^/    /'
python3 scripts/theme-sync.py --no-apply > "$OUT/theme-sync-unpinned.log"
hyprctl reload >/dev/null; sleep 2
grep -q 'masked=-' "$OUT/theme-sync-unpinned.log" \
    || bad "P3: theme-sync still thinks something is pinned after the unpin"
BACK=$(hyprctl getoption plugin:hyprdrive:dock:indicator_color -j | python3 -c "import json,sys; print(json.load(sys.stdin)['int'])")
echo "    indicator_color is back to the derived $BACK"
[ "$BACK" = "4278255360" ] && bad "P3: unpinning left the pinned value in place"

alive_or_die "the whole run"
echo
[ $FAIL = 0 ] && echo "X62 PASS -- a hand-written line and a pin both survived everything regenerating under them" || echo "X62 FAIL"
exit $FAIL
