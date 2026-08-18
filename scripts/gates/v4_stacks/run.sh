#!/usr/bin/env bash
# v4_stacks -- V11 SPEC V4, DOCK STACKS.
#
# A stack is a file or folder pinned to the dock as a first-class cell, opening
# into a FAN or a GRID of its contents, with its settings in the dock's own
# context menu and no external prefs panel.
#
# DATA SAFETY IS THE FIRST THING IN THIS FILE, not a note at the bottom. This
# gate MOVES FILES. Every path it touches is created by this run under a
# mktemp -d root, every destructive command asserts that root's shape before it
# runs, and nothing outside it is ever named. The gate would rather die than
# guess.
#
# WHY THE DOCK IS RECONFIGURED FIRST. A stack is a CELL: it changes
# items.size(), which changes `slots`, which changes both the icon size and the
# pill width that metrics() returns -- so a stack moves every other cell on the
# dock. The suite's answer is that gate_slate clears every stack, so no other
# gate ever sees one (see scripts/lib/rig.sh). This gate's own answer is to
# turn favourites, trash and Show Applications OFF, so the dock contains
# exactly [running classes] ++ [stacks] and v4_stack_cell.py's arithmetic is
# exact rather than approximately right.
#
# FAIL-ON-OLD. Every phase reds on the parent for the same reason: the parent
# has no `hyprdrive:stack` dispatcher at all, so P1's pin does not happen, no
# cell appears, and every phase after it is measuring a dock with nothing on
# it. P1 asserts the state file EXISTS with the pinned paths in it -- on the
# parent it is never created. Recorded in the log, not just claimed: the gate
# prints the dispatcher's own answer.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=${RIG_EVIDENCE:-/mnt/host/zrig}/v4/stacks; mkdir -p "$OUT"
rm -f "$OUT"/*.png "$OUT"/*.txt
FAIL=0
CELL=scripts/v4_stack_cell.py
GRADE=scripts/v4_stacks_gate.py

gate_slate v4_stacks >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }
[ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_pause 30min

# ------------------------------------------------------------- the fixtures --
# mktemp -d, so the name is unpredictable and cannot collide with anything the
# user owns. WORK is re-checked before every removal.
WORK=$(mktemp -d /tmp/v4stacks.XXXXXXXX) || { echo "FAIL no fixture root"; exit 1; }
case "$WORK" in
    /tmp/v4stacks.*) ;;
    *) echo "FAIL fixture root '$WORK' is not under /tmp/v4stacks. -- refusing to run"; exit 1 ;;
esac

SRC=$WORK/src; DST=$WORK/dst; RO=$WORK/ro
mkdir -p "$SRC" "$DST" "$RO"
# Five files, named so the by-name sort is unambiguous and so the grader's row
# count is a number this script chose rather than a number it read back.
for n in alpha bravo charlie delta echo; do
    printf 'v4 fixture %s\n%s\n' "$n" "$(date +%s%N)" > "$SRC/$n.txt"
done
NFILES=5
MOVEME=$SRC/alpha.txt
SUM_BEFORE=$(sha256sum "$MOVEME" | awk '{print $1}')

cleanup() {
    # Belt and braces: the same shape assertion again, at the only place that
    # deletes anything.
    case "${WORK:-}" in
        /tmp/v4stacks.*) chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK" ;;
    esac
    dsp "hl.plugin.hyprdrive.stack([[clear]])" >/dev/null 2>&1
    ov off
    headless_off
    hyprwall_resume
}
trap cleanup EXIT

echo "    fixtures under $WORK ($NFILES files in src/, empty dst/, unwritable ro/)"

headless_on || exit 1

# The dock contains exactly [running classes] ++ [stacks] from here on.
cfg_dock "show_favorites=false, show_trash=false, show_mounts=false, show_apps_button=false, autohide=false"
sleep 0.8
opt_want $RIG_KEY:dock:show_favorites false || { echo "FAIL dock config did not take"; exit 1; }

pkill -x kitty 2>/dev/null; sleep 1.0
dsp "hl.dsp.focus({monitor = \"$RIG_MON\"})"; sleep 0.4
dsp 'hl.dsp.focus({workspace = 1})'; sleep 0.5
fixture_kitty kitty 300 200 900 600 '#101820' 'clear; sleep infinity' || exit 1
killothers kitty; sleep 0.8

shoot() { grim -o "$RIG_MON" "$OUT/$1.png" >/dev/null 2>&1; sleep 0.2; }
stackcell() { hyprctl clients -j | python3 "$CELL" stack "$1" "$2"; }
pillbox()   { hyprctl clients -j | python3 "$CELL" pill "$1"; }

# ============================================================== P1  THE PIN ==
echo "--- P1 PIN: two folders become two dock cells, and a state file"
shoot p1-before
PIN1=$(hyprctl dispatch "hl.plugin.hyprdrive.stack([[pin $SRC]])" 2>&1)
PIN2=$(hyprctl dispatch "hl.plugin.hyprdrive.stack([[pin $DST]])" 2>&1)
sleep 1.2
echo "    pin src -> $PIN1"
echo "    pin dst -> $PIN2"

# THE STATE FILE. This is the arm that cannot pass on the parent: the parent
# has no stack dispatcher, so nothing ever writes this path.
if [ ! -s "$RIG_STACKS" ]; then
    echo "FAIL no stacks state file at $RIG_STACKS -- the pin did not happen"
    FAIL=1
else
    cp "$RIG_STACKS" "$OUT/state-after-pin.txt"
    echo "    state file:"; sed 's/^/      /' "$RIG_STACKS"
    grep -qF "$SRC" "$RIG_STACKS" && grep -qF "$DST" "$RIG_STACKS" \
        || { echo "FAIL the state file does not name both pinned folders"; FAIL=1; }
    head -1 "$RIG_STACKS" | grep -q "hyprdrive stacks v" \
        || { echo "FAIL the state file carries no version header"; FAIL=1; }
fi

shoot p1-after
read -r PX PY PW PH <<< "$(pillbox 2)"
python3 "$GRADE" diff "$OUT/p1-after.png" "$OUT/p1-before.png" "$PX" "$PY" "$PW" "$PH" 900 || FAIL=1

# ============================================================== P2  THE FAN ==
echo "--- P2 FAN: a click on the src cell opens $((NFILES + 1)) rows"
read -r SCX SCY <<< "$(stackcell 0 2)"
echo "    src stack cell predicted at $SCX,$SCY"
shoot p2-base
warp_or_die "$SCX" "$SCY"; sleep 0.4
ydotool click 0x40 >/dev/null 2>&1; sleep 0.05; ydotool click 0x80 >/dev/null 2>&1
sleep 1.2
shoot p2-fan
# NFILES rows + one action row ("Open in Files"), and NOTHING one row past it.
python3 "$GRADE" fan "$OUT/p2-fan.png" "$OUT/p2-base.png" "$SCX" "$PY" "$((NFILES + 1))" || FAIL=1

# Dismiss with a press in the gutter, which must NOT be claimed.
warp_or_die 1280 300; sleep 0.3
ydotool click 0x40 >/dev/null 2>&1; sleep 0.05; ydotool click 0x80 >/dev/null 2>&1
sleep 1.0

# ============================================ P3  THE MENU AND THE TOGGLE ==
echo "--- P3 MENU: right-click lists the view toggle; using it re-renders as a grid"
shoot p3-base
warp_or_die "$SCX" "$SCY"; sleep 0.4
ydotool click 0xC1 >/dev/null 2>&1     # BTN_RIGHT, down+up in one code
sleep 1.0
shoot p3-menu
python3 "$GRADE" diff "$OUT/p3-menu.png" "$OUT/p3-base.png" "$((SCX - 200))" "$((PY - 220))" 400 220 900 \
    || { echo "FAIL no context plate above the stack cell"; FAIL=1; }

# The first row of a folder stack's menu is the view toggle (DockStacks: view,
# sort, separator, open, unpin). Rows are laid out bottom-up from the pill, so
# the FIRST row sits highest; the menu's own geometry decides where, and the
# gate clicks by walking down from the plate top until the state file changes.
# That is a read-back, and it is deliberate HERE and nowhere else: the menu's
# row heights are its rendered text's heights, which no arithmetic outside the
# renderer can predict (Dock.hpp:165-173 says so).
TOGGLED=0
for dy in 150 132 114 96 78 60 42; do
    warp_or_die "$SCX" "$((PY - dy))" 2>/dev/null || continue
    sleep 0.2
    ydotool click 0x40 >/dev/null 2>&1; sleep 0.05; ydotool click 0x80 >/dev/null 2>&1
    sleep 0.8
    if grep -q "^grid" "$RIG_STACKS" 2>/dev/null; then TOGGLED=1; echo "    the view row was at pill-y minus $dy"; break; fi
    # A miss dismissed the menu; reopen and try the next row.
    warp_or_die "$SCX" "$SCY"; sleep 0.3
    ydotool click 0xC1 >/dev/null 2>&1
    sleep 0.8
done
if [ $TOGGLED != 1 ]; then
    echo "FAIL no menu row switched the stack to a grid"
    grep -qF "$SRC" "$RIG_STACKS" 2>/dev/null \
        || echo "     ...and the src stack is GONE from the store: a row was hit, but the wrong one"
    FAIL=1
fi

cp "$RIG_STACKS" "$OUT/state-after-toggle.txt" 2>/dev/null
echo "    state file after the toggle:"; sed 's/^/      /' "$RIG_STACKS" 2>/dev/null

# PER-STACK, not global: the OTHER stack must still say fan.
if [ "$(grep -c '^grid' "$RIG_STACKS" 2>/dev/null || echo 0)" != 1 ]; then
    echo "FAIL the toggle changed more than one stack -- the view is supposed to be per-stack"
    FAIL=1
fi

echo "--- P4 GRID: the same cell now opens a grid, and it is not the fan"
shoot p4-base
warp_or_die "$SCX" "$SCY"; sleep 0.4
ydotool click 0x40 >/dev/null 2>&1; sleep 0.05; ydotool click 0x80 >/dev/null 2>&1
sleep 1.2
shoot p4-grid
python3 "$GRADE" grid "$OUT/p4-grid.png" "$OUT/p4-base.png" "$SCX" "$PY" || FAIL=1
# FAN != GRID, on the same cell in the same session: the A/B the spec asks for.
python3 "$GRADE" diff "$OUT/p4-grid.png" "$OUT/p2-fan.png" "$((SCX - 400))" "$((PY - 400))" 800 400 1500 \
    || { echo "FAIL the grid frame and the fan frame are the same picture"; FAIL=1; }

warp_or_die 1280 300; sleep 0.3
ydotool click 0x40 >/dev/null 2>&1; sleep 0.05; ydotool click 0x80 >/dev/null 2>&1
sleep 0.8

# Back to a fan for the move phase: a fan row is a bigger, simpler target.
hyprctl dispatch "hl.plugin.hyprdrive.stack([[view fan $SRC]])" >/dev/null 2>&1
sleep 0.6

# ============================================================= P5  THE MOVE ==
echo "--- P5 MOVE: drag a file out of the fan onto the dst cell"
read -r DCX DCY <<< "$(stackcell 1 2)"
echo "    dst stack cell predicted at $DCX,$DCY"
warp_or_die "$SCX" "$SCY"; sleep 0.4
ydotool click 0x40 >/dev/null 2>&1; sleep 0.05; ydotool click 0x80 >/dev/null 2>&1
sleep 1.2

# The first fan row sits one FAN_STEP above the pill, right-aligned near the
# cell; its icon column is at the cell's x.
ROW1Y=$((PY - 10 - 56 + 26))
warp_or_die "$SCX" "$ROW1Y"; sleep 0.4
ydotool click 0x40                       # press on the row
for step in 1 2 3 4 5 6 7 8; do
    warp $(( SCX + (DCX - SCX) * step / 8 )) $(( ROW1Y + (DCY - ROW1Y) * step / 8 ))
    sleep 0.06
done
warp_or_die "$DCX" "$DCY"; sleep 0.4
ydotool click 0x80                       # release over the dst cell
sleep 1.5

MOVED=$DST/alpha.txt
if [ -e "$MOVEME" ]; then
    echo "FAIL the source file is still at $MOVEME -- nothing moved"
    FAIL=1
elif [ ! -e "$MOVED" ]; then
    echo "FAIL the file is at neither end: gone from src, absent from dst"
    FAIL=1
else
    SUM_AFTER=$(sha256sum "$MOVED" | awk '{print $1}')
    echo "    source gone, destination present"
    echo "    sha256 before $SUM_BEFORE"
    echo "    sha256 after  $SUM_AFTER"
    [ "$SUM_BEFORE" = "$SUM_AFTER" ] || { echo "FAIL the file changed in transit"; FAIL=1; }
fi

# ==================================================== P6  THE FAILURE ARM ==
echo "--- P6 REFUSAL: a move into an unwritable folder must not happen"
chmod 500 "$RO"
hyprctl dispatch "hl.plugin.hyprdrive.stack([[pin $RO]])" >/dev/null 2>&1
sleep 1.0
RO_BEFORE=$(sha256sum "$SRC/bravo.txt" | awk '{print $1}')

read -r RCX RCY <<< "$(stackcell 2 3)"
read -r SCX3 SCY3 <<< "$(stackcell 0 3)"     # the cells moved: three stacks now
warp_or_die "$SCX3" "$SCY3"; sleep 0.4
ydotool click 0x40 >/dev/null 2>&1; sleep 0.05; ydotool click 0x80 >/dev/null 2>&1
sleep 1.2
ROW1Y3=$((PY - 10 - 56 + 26))
warp_or_die "$SCX3" "$ROW1Y3"; sleep 0.4
ydotool click 0x40 >/dev/null 2>&1
for step in 1 2 3 4 5 6 7 8; do
    warp $(( SCX3 + (RCX - SCX3) * step / 8 )) $(( ROW1Y3 + (RCY - ROW1Y3) * step / 8 ))
    sleep 0.06
done
warp_or_die "$RCX" "$RCY"; sleep 0.4
ydotool click 0x80 >/dev/null 2>&1
sleep 1.5

if [ ! -e "$SRC/bravo.txt" ]; then
    echo "FAIL the file left its folder for an unwritable destination"
    FAIL=1
else
    RO_AFTER=$(sha256sum "$SRC/bravo.txt" | awk '{print $1}')
    [ "$RO_BEFORE" = "$RO_AFTER" ] \
        && echo "    the file is untouched at source, checksum unchanged" \
        || { echo "FAIL the refused file changed anyway"; FAIL=1; }
fi
[ -z "$(ls -A "$RO" 2>/dev/null)" ] || { echo "FAIL something landed in the unwritable folder"; FAIL=1; }

warp_or_die 1280 300; sleep 0.3
ydotool click 0x40 >/dev/null 2>&1; sleep 0.05; ydotool click 0x80 >/dev/null 2>&1
sleep 0.8

# ============================================================ P7  THE UNPIN ==
echo "--- P7 UNPIN: the cells and the state go away"
shoot p7-before
for p in "$SRC" "$DST" "$RO"; do
    hyprctl dispatch "hl.plugin.hyprdrive.stack([[unpin $p]])" >/dev/null 2>&1
done
sleep 1.2
shoot p7-after

if [ -s "$RIG_STACKS" ] && grep -qF "$SRC" "$RIG_STACKS"; then
    echo "FAIL the unpinned folder is still in the state file"
    FAIL=1
else
    echo "    the state file no longer names any fixture folder"
fi
read -r PX2 PY2 PW2 PH2 <<< "$(pillbox 0)"
python3 "$GRADE" diff "$OUT/p7-after.png" "$OUT/p7-before.png" "$PX" "$PY" "$PW" "$PH" 900 \
    || { echo "FAIL the dock did not change when three cells were removed"; FAIL=1; }

echo
[ $FAIL = 0 ] && echo "PASS v4_stacks" || echo "FAIL v4_stacks"
exit $FAIL
