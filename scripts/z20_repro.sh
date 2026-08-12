#!/usr/bin/env bash
# Z20 REPRO -- "invisible tile after in-overview restore".
#
# The defect on record: minimize a window while the overview is up and restore
# it while the overview is still up, and its tile comes back CLICKABLE BUT
# INVISIBLE. The grid and the hit-test iterate the live window list, so they
# find it; the renderer walks the overview's own draw list (img->windows), and
# `setHidden(false)` fires no compositor event, so nothing ever rebuilds that
# list. Recorded fixed around P6 -- Dock.cpp calls `IOverview::refreshWindows()`
# at both unhide sites (Dock.cpp:3624 and :3953) -- but no repro script was ever
# written, so "fixed" had never been re-run against the behaviour.
#
# This is that script. It exits 0 when Z20 does NOT reproduce.
#
# THE ONE THING THIS TEST CANNOT DO IS FIND THE TILE BY LOOKING FOR IT.
# An invisible tile is invisible: a locator that hunts the blue tile in the
# restored frame cannot tell "it came back somewhere else" from "it did not come
# back", and if it cannot find it there is nothing to click. So the cell is
# derived from the OTHER window:
#
#   * before the minimize, both tiles are visible and the grid's two cells are
#     read off them;
#   * the overview re-flows while one window is minimized and the two windows
#     come back in either order -- MEASURED: they swap, blue returns to the cell
#     amber had -- so the restored frame is located by AMBER, and the cell amber
#     is NOT in is the cell blue must be in;
#   * VISIBLE asks whether blue is drawn in that cell, and CLICKABLE clicks that
#     cell's centre and asks the compositor what it activated.
#
# Z20's signature is CLICKABLE passing while VISIBLE fails. Neither half is
# redundant: a tile that vanished from the layout outright fails only CLICKABLE.
#
# The must-move control is the minimize itself: if the tile is still there in
# 20-minimized then nothing was minimized and "it came back" means nothing.
# That control has already earned its place -- it caught this script calling
# `hl.plugin.hyprdrive.minimize(...)` without `hl.dispatch(...)` around it,
# which builds the descriptor, returns it, dispatches nothing, and exits 0.
set -u
cd "$(dirname "$0")/.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=/mnt/host/zrig/danglingA2/z20; mkdir -p "$OUT"
FAIL=0
bad() { echo "FAIL $*"; FAIL=1; }

hyprwall_pause
trap hyprwall_resume EXIT

gate_slate z20_repro >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }
MON=$RIG_MON_NAME
shot() { grim -o "$MON" "$OUT/$1.png"; }

# wp17 is fully greyscale, so a saturated blob over the wallpaper is a fixture
# and nothing else. Blue is the subject; amber is the landmark the restored
# frame is located by.
# BOTH LIVE WINDOWS SIT ABOVE THE OVERVIEW'S CELL CENTRES, on purpose.
# Clicking a tile closes the overview, and this session is follow_mouse, so the
# pointer -- still parked where the tile was -- takes focus to whatever LIVE
# window is under it a moment later. Measured: the click activated Z20BLUE and
# the answer read Z20AMBER, because amber's live window covered the cell centre
# that had just been clicked. Cells land near y 930-960; these end at y 530.
fixture_kitty Z20BLUE  300 150 900 380 '#0000ff' || exit 1
fixture_kitty Z20AMBER 1400 150 900 380 '#ff8800' || exit 1
dsp 'hl.dsp.focus({window = [[class:Z20BLUE]]})'; sleep 0.8

ov on; sleep 2.5
shot 10-open-before

dsp 'hl.dsp.focus({window = [[class:Z20BLUE]]})'; sleep 0.6
dsp "hl.plugin.$RIG_NS.minimize([[window]])"
sleep 3.0
shot 20-minimized
alive_or_die "after the in-overview minimize"

dsp "hl.plugin.$RIG_NS.minimize([[restore]])"
sleep 3.5
shot 30-restored
alive_or_die "after the in-overview restore"

python3 - "$OUT" <<'PY' || FAIL=1
import pathlib, sys
import numpy as np
from PIL import Image
sys.path.insert(0, "scripts")
from g1_gate import S, DILATE, dilate, largest        # one blob implementation

OUT = pathlib.Path(sys.argv[1])
def load(n): return np.asarray(Image.open(OUT / f"{n}.png").convert("RGB")).astype(int)

# The accent this rice draws its chrome in is #adc6ff -- light blue, B-R = 82 --
# so the blue test needs a margin well above that. A fixture at the rice's 0.92
# window opacity over the greyscale wallpaper measures about (23, 0, 229):
# B-R = 206. 100 sits between them with room on both sides.
def blue(a):  return ((a[:, :, 2] - a[:, :, 0]) > 100) & (a[:, :, 2] > 150)
def amber(a): return ((a[:, :, 0] - a[:, :, 2]) > 100) & (a[:, :, 0] > 140)

def blob(m):
    cells, box = largest(dilate(m[::S, ::S], DILATE))
    return box, cells * S * S

def inside(m, box, shrink=0.20):
    """How many px of `m` fall inside `box`, inset so a neighbouring cell's
    tile cannot leak into the answer."""
    x, y, w, h = box
    ix, iy = int(w * shrink / 2), int(h * shrink / 2)
    return int(m[y + iy:y + h - iy, x + ix:x + w - ix].sum())

before, mini, after = load("10-open-before"), load("20-minimized"), load("30-restored")
if np.array_equal(before, mini) or np.array_equal(mini, after):
    print("FAIL identical frames -- the output was frozen, this proves nothing")
    sys.exit(1)

b_box, b_area = blob(blue(before))
a_box, a_area = blob(amber(before))
print(f"    before     blue tile {b_box} {b_area} px | amber tile {a_box} {a_area} px")
m_box, m_area = blob(blue(mini))
print(f"    minimized  blue {m_box} {m_area} px")
am_box, am_area = blob(amber(after))
print(f"    restored   amber tile {am_box} {am_area} px")

ok = True
if b_area < 40000 or a_area < 40000:
    print(f"FAIL there is no grid to measure: tiles are {b_area} and {a_area} px")
    sys.exit(1)
if m_area > 0.25 * b_area:
    print(f"FAIL CONTROL: blue is still {m_area} px after the minimize "
          f"({100*m_area/b_area:.0f}% of before) -- nothing was minimized")
    ok = False

# Which cell did amber come back to? The other one is blue's.
cells = {"blue-cell": b_box, "amber-cell": a_box}
def centre(b): return (b[0] + b[2] / 2, b[1] + b[3] / 2)
amc = centre(am_box)
which = min(cells, key=lambda k: abs(centre(cells[k])[0] - amc[0]))
target = cells["blue-cell" if which == "amber-cell" else "amber-cell"]
print(f"    restored   amber is in the {which}, so blue's cell is {target}"
      f"{'  (they swapped)' if which == 'blue-cell' else ''}")

# VISIBLE -- is blue actually DRAWN in that cell?
drawn = inside(blue(after), target)
was = inside(blue(before), b_box)
print(f"    VISIBLE    blue px inside that cell: {drawn} (it was {was} in its own cell before)")
if drawn < 0.60 * was:
    print(f"FAIL VISIBLE: blue's cell holds {drawn} px of blue, {100*drawn/was:.0f}% of "
          f"what a drawn tile has -- an invisible tile, which is Z20")
    ok = False
else:
    print(f"    VISIBLE    the tile is drawn in its cell, {100*drawn/was:.0f}% of before")

(OUT / "hit.txt").write_text("%d %d\n" % (int(centre(target)[0]), int(centre(target)[1])))
sys.exit(0 if ok else 1)
PY

# --- CLICKABLE: the centre of the cell blue must be in -----------------------
read -r HX HY < "$OUT/hit.txt"
echo "    clicking blue's cell centre at $HX,$HY"
click "$HX" "$HY"
sleep 2.5
shot 40-afterclick
ACTIVE=$(hyprctl activewindow -j | python3 -c "import json,sys; print(json.load(sys.stdin).get('class',''))" 2>/dev/null)
hyprctl clients -j | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    print('      live %-9s at %s size %s' % (c.get('class'), c.get('at'), c.get('size')))" 2>/dev/null
if [ "$ACTIVE" = Z20BLUE ]; then
    echo "    CLICKABLE  the click at that cell activated Z20BLUE"
else
    bad "CLICKABLE: the click activated '$ACTIVE', not Z20BLUE"
fi

ov_off_settled
alive_or_die "the whole run"
echo
[ $FAIL = 0 ] && echo "Z20 DOES NOT REPRODUCE -- the restored tile is drawn in its cell and clicking that cell activates it" \
              || echo "Z20 REPRODUCES"
exit $FAIL
