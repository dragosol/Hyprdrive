#!/usr/bin/env bash
# v5_sushi_dock -- V11 SPEC V5, THE SPACEBAR PREVIEW, and the scope of its claim.
#
# With a stack's fan open and the pointer over one of its items, SPACE toggles a
# gnome-sushi preview of THAT item. Everywhere else SPACE is the application's
# key and must arrive at the application untouched -- which is the half of this
# gate that matters most. A feature that eats the space bar in a text editor is
# not a feature.
#
# WHAT SUSHI IS, MEASURED RATHER THAN ASSUMED. On Fedora the package is called
# `sushi` and `gnome-sushi` resolves to nothing; it ships no .desktop file, only
# /usr/libexec/org.gnome.NautilusPreviewer behind a D-Bus activation stanza.
# The interface (busctl --user introspect org.gnome.NautilusPreviewer
# /org/gnome/NautilusPreviewer) is:
#
#     org.gnome.NautilusPreviewer2.ShowFile(s uri, s windowHandle,
#                                           b closeIfAlreadyShown, s token)
#
# -- note the 2 on the INTERFACE and not on the name or the path. With
# closeIfAlreadyShown true, the same uri closes what is up, which is the toggle
# V5 asks for and is sushi's own behaviour rather than something bolted on here.
# The window it maps reports class `org.gnome.NautilusPreviewer` and titles
# itself with the file's BASENAME, which is what P1 grades: a preview of the
# hovered item, not merely a preview.
#
# THE DOCK GAINS A CELL WHILE A PREVIEW IS UP, and that is correct rather than
# a fault -- the dock lists running window classes and a preview is a running
# window. So the fan MOVES with the cell it is anchored to, and this gate
# re-predicts the cell after the preview appears instead of asserting a
# pixel-identical dock, which would be asserting that the dock ignores a window.
# What it does assert is that the fan is STILL THERE, at the position its new
# anchor puts it, with all of its rows.
#
# FAIL-ON-OLD. The parent has no SPACE handling at all: P1's first injection
# maps no client (0 where 1 is wanted) and the byte lands in the terminal
# instead of being consumed, so P1 reds twice over -- once for the preview that
# did not happen and once for the claim that did not. P2 is GREEN on both
# builds by design: it is the regression guard, not a discriminator.
#
# DATA SAFETY. Every path is created by this run under a mktemp -d root and the
# root's shape is re-asserted before the one removal. Nothing outside it is
# named, and nothing here moves or deletes a file the user owns.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=${RIG_EVIDENCE:-/mnt/host/zrig}/v5/dock; mkdir -p "$OUT"
rm -f "$OUT"/*.png "$OUT"/*.txt
FAIL=0
CELL=scripts/v4_stack_cell.py
V4GRADE=scripts/v4_stacks_gate.py
GRADE=scripts/v5_sushi_gate.py

command -v sushi >/dev/null 2>&1 || [ -x /usr/libexec/org.gnome.NautilusPreviewer ] || {
    echo "FAIL gnome-sushi is not installed in this guest (Fedora package name: sushi)"
    exit 1
}

gate_slate v5_sushi_dock >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }
[ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_pause 30min

WORK=$(mktemp -d /tmp/v5sushi.XXXXXXXX) || { echo "FAIL no fixture root"; exit 1; }
case "$WORK" in
    /tmp/v5sushi.*) ;;
    *) echo "FAIL fixture root '$WORK' is not under /tmp/v5sushi. -- refusing to run"; exit 1 ;;
esac
SRC=$WORK/src; KEYS=$WORK/keys.bin
mkdir -p "$SRC"

# Three previewable files, named so the by-name sort is unambiguous: the fan
# draws them bottom-up, so alpha.png is ROW 0, the one nearest the dock.
python3 - "$SRC" <<'PY'
import pathlib, sys
from PIL import Image
d = pathlib.Path(sys.argv[1])
for i, n in enumerate(("alpha", "bravo", "charlie")):
    im = Image.new("RGB", (600, 450))
    px = im.load()
    for x in range(600):
        for y in range(450):
            px[x, y] = ((x * (3 + i)) % 256, (y * (5 + i)) % 256, ((x ^ y) * (7 + i)) % 256)
    im.save(d / (n + ".png"))
PY
NFILES=3
ROW0=alpha.png

closep() { timeout 10 busctl --user call org.gnome.NautilusPreviewer /org/gnome/NautilusPreviewer \
                   org.gnome.NautilusPreviewer2 Close >/dev/null 2>&1; }

cleanup() {
    closep
    case "${WORK:-}" in /tmp/v5sushi.*) rm -rf "$WORK" ;; esac
    dsp "hl.plugin.hyprdrive.stack([[clear]])" >/dev/null 2>&1
    pkill -x kitty 2>/dev/null
    ov off
    headless_off
    hyprwall_resume
}
trap cleanup EXIT

echo "    fixtures under $WORK ($NFILES previewable files, row 0 = $ROW0)"
headless_on || exit 1

# The dock contains exactly [running classes] ++ [stacks] from here on, so
# v4_stack_cell.py's arithmetic is exact rather than approximately right.
cfg_dock "show_favorites=false, show_trash=false, show_mounts=false, show_apps_button=false, autohide=false"
sleep 0.8
opt_want $RIG_KEY:dock:show_favorites false || { echo "FAIL dock config did not take"; exit 1; }

# THE RECEIVER. A kitty whose shell reads its tty ONE RAW BYTE AT A TIME and
# appends it to a file -- dd, not cat, because dd write()s each byte straight
# through while cat's stdio would sit on it in a buffer and the gate would be
# grading libc rather than the compositor. This is how "the key reached the
# application" is proved: not by a pixel, by the byte itself.
pkill -x kitty 2>/dev/null; sleep 1.0
dsp "hl.dsp.focus({monitor = \"$RIG_MON\"})"; sleep 0.4
dsp 'hl.dsp.focus({workspace = 1})'; sleep 0.5
fixture_kitty zspace 300 200 900 600 '#101820' \
    "clear; stty raw -echo; while :; do dd bs=1 count=1 2>/dev/null; done > $KEYS" || exit 1
killothers zspace; sleep 0.8
: > "$KEYS" 2>/dev/null || true
sleep 0.5

bytes()  { wc -c < "$KEYS" 2>/dev/null | tr -d ' '; }
lastch() { tail -c 1 "$KEYS" 2>/dev/null | od -An -tx1 | tr -d ' \n'; }
sushin() { hyprctl clients -j | python3 -c "
import json,sys
cs=[c for c in json.load(sys.stdin) if c['class']=='org.gnome.NautilusPreviewer']
print(len(cs))"; }
sushi1() { hyprctl clients -j | python3 -c "
import json,sys
cs=[c for c in json.load(sys.stdin) if c['class']=='org.gnome.NautilusPreviewer']
print('%s %d %d %d %d %s' % ((cs[0]['title'],)+tuple(cs[0]['at'])+tuple(cs[0]['size'])+(cs[0]['floating'],)) if cs else 'NONE 0 0 0 0 False')"; }
shoot()  { grim -o "$RIG_MON" "$OUT/$1.png" >/dev/null 2>&1; sleep 0.2; }
# WHO WOULD HAVE GOT THE KEY. "The terminal's byte count did not move" only
# means the key was consumed if the terminal was the one it was headed for --
# otherwise it is a measurement of an unfocused window, which is no measurement
# at all. Asserted at every injection rather than set up once: the click that
# opens the fan, and the preview window itself, are both things that could have
# taken the focus in between.
focused() { hyprctl activewindow -j 2>/dev/null | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('class') or 'NONE')
except Exception: print('NONE')"; }
want_focus() { # want_focus CLASS LABEL
    local got; got=$(focused)
    if [ "$got" != "$1" ]; then
        echo "FAIL $2: the focused window is '$got', not '$1' -- a key sent now proves nothing"
        FAIL=1
    else
        echo "    focus is $got ($2)"
    fi
}
stackcell() { hyprctl clients -j | python3 "$CELL" stack "$1" "$2"; }
pillbox()   { hyprctl clients -j | python3 "$CELL" pill "$1"; }

closep; sleep 1.0
[ "$(sushin)" = 0 ] || { echo "FAIL a previewer window was already up before the gate started"; FAIL=1; }

# =========================================================== P1  THE PREVIEW ==
echo "--- P1 PREVIEW: fan open, pointer on row 0, SPACE"
hyprctl dispatch "hl.plugin.hyprdrive.stack([[pin $SRC]])" >/dev/null 2>&1
sleep 1.2
grep -qF "$SRC" "$RIG_STACKS" 2>/dev/null || { echo "FAIL the fixture folder did not pin"; FAIL=1; }

shoot p1-base
read -r PX PY PW PH <<< "$(pillbox 1)"
read -r SCX SCY <<< "$(stackcell 0 1)"
echo "    pill $PX,$PY ${PW}x$PH   stack cell $SCX,$SCY"

warp_or_die "$SCX" "$SCY"; sleep 0.4
ydotool click 0x40 >/dev/null 2>&1; sleep 0.05; ydotool click 0x80 >/dev/null 2>&1
sleep 1.5
shoot p1-fan
python3 "$V4GRADE" fan "$OUT/p1-fan.png" "$OUT/p1-base.png" "$SCX" "$PY" "$((NFILES + 1))" \
    || { echo "FAIL the fan did not open, so there is nothing to hover"; FAIL=1; }

# Row 0 sits one FAN_STEP above the pill, FAN_ROW_H tall -- the same arithmetic
# v4_stacks drags out of.
ROW0Y=$((PY - 10 - 56 + 26))
warp_or_die "$SCX" "$ROW0Y"; sleep 0.6
echo "    hovering row 0 at $SCX,$ROW0Y"

want_focus zspace "P1, before the SPACE"
BEFORE_BYTES=$(bytes)
ydotool key 57:1 57:0
sleep 3.0
shoot p1-sushi

N=$(sushin)
read -r TITLE SX SY SW SH SFLOAT <<< "$(sushi1)"
echo "    previewer clients: $N   title '$TITLE'  at $SX,$SY  ${SW}x$SH  floating $SFLOAT"
if [ "$N" != 1 ]; then
    echo "FAIL SPACE over a fan item produced $N previewer windows, wanted 1"
    FAIL=1
else
    [ "$TITLE" = "$ROW0" ] || { echo "FAIL the preview is of '$TITLE', not of the hovered item '$ROW0'"; FAIL=1; }
    [ "$SW" -gt 0 ] && [ "$SH" -gt 0 ] || { echo "FAIL the preview window has no size"; FAIL=1; }
    [ "$SFLOAT" = True ] || { echo "FAIL the preview did not float"; FAIL=1; }
fi

# THE CLAIM. The key was consumed, so the terminal underneath -- which is
# focused, and which counts every byte its tty delivers -- must not have moved.
AFTER_BYTES=$(bytes)
echo "    bytes at the focused terminal: $BEFORE_BYTES before, $AFTER_BYTES after"
if [ "$AFTER_BYTES" != "$BEFORE_BYTES" ]; then
    echo "FAIL the claimed SPACE reached the application anyway -- the key was not consumed"
    FAIL=1
fi

# STILL OPEN, and at the position its cell has NOW: a preview is a running
# window, so the dock grew a cell and the fan followed its anchor. Re-predicted
# rather than assumed, which is also how a fan that failed to follow would red.
read -r PX2 PY2 PW2 PH2 <<< "$(pillbox 1)"
read -r SCX2 SCY2 <<< "$(stackcell 0 1)"
echo "    with the preview up the stack cell is at $SCX2,$SCY2 (was $SCX,$SCY)"
python3 "$V4GRADE" fan "$OUT/p1-sushi.png" "$OUT/p1-base.png" "$SCX2" "$PY2" "$((NFILES + 1))" \
    || { echo "FAIL the fan is not open any more, or it did not follow its cell"; FAIL=1; }
grep -qF "$SRC" "$RIG_STACKS" 2>/dev/null \
    || { echo "FAIL the stack left the dock when the preview opened"; FAIL=1; }

# ============================================================= P2  THE TOGGLE ==
echo "--- P2 TOGGLE: SPACE again on the same item takes it away"
# The preview window mapped and took the focus, which is exactly why P2 cannot
# reuse P1's answer: the byte count standing still now has to be re-earned.
echo "    the focused window is now $(focused)"
BEFORE_BYTES=$(bytes)
ydotool key 57:1 57:0
sleep 3.0
shoot p2-closed
N=$(sushin)
echo "    previewer clients after the second SPACE: $N"
[ "$N" = 0 ] || { echo "FAIL the second SPACE did not close the preview"; FAIL=1; }
[ "$(bytes)" = "$BEFORE_BYTES" ] || { echo "FAIL the second SPACE also reached the application"; FAIL=1; }

read -r PX3 PY3 PW3 PH3 <<< "$(pillbox 1)"
read -r SCX3 SCY3 <<< "$(stackcell 0 1)"
python3 "$V4GRADE" fan "$OUT/p2-closed.png" "$OUT/p1-base.png" "$SCX3" "$PY3" "$((NFILES + 1))" \
    || { echo "FAIL the fan did not survive the toggle"; FAIL=1; }

# ======================================================== P3  THE PASS-THROUGH ==
# The regression guard, and the reason the claim is decided by the same read
# that decides what to preview: no item under the pointer, no claim.
echo "--- P3 PASS-THROUGH: SPACE anywhere else is still the application's key"

echo "  P3a fan OPEN, pointer NOT over a row"
dsp 'hl.dsp.focus({window = [[class:zspace]]})'; sleep 0.6
warp_or_die 700 450; sleep 0.6         # over the terminal, which is not the fan
want_focus zspace "P3a"
BEFORE_BYTES=$(bytes)
ydotool key 57:1 57:0
sleep 1.5
AFTER_BYTES=$(bytes)
LAST=$(lastch)
echo "    bytes $BEFORE_BYTES -> $AFTER_BYTES, last byte 0x$LAST"
if [ "$AFTER_BYTES" != "$((BEFORE_BYTES + 1))" ] || [ "$LAST" != 20 ]; then
    echo "FAIL a SPACE over no fan item did not reach the focused terminal"
    FAIL=1
fi
[ "$(sushin)" = 0 ] || { echo "FAIL a SPACE over no fan item opened a preview anyway"; FAIL=1; }

echo "  P3b fan CLOSED"
warp_or_die 1280 300; sleep 0.3
ydotool click 0x40 >/dev/null 2>&1; sleep 0.05; ydotool click 0x80 >/dev/null 2>&1
sleep 1.2
dsp 'hl.dsp.focus({window = [[class:zspace]]})'; sleep 0.6
warp_or_die 700 450; sleep 0.5
want_focus zspace "P3b"
BEFORE_BYTES=$(bytes)
ydotool key 57:1 57:0
sleep 1.5
AFTER_BYTES=$(bytes)
LAST=$(lastch)
echo "    bytes $BEFORE_BYTES -> $AFTER_BYTES, last byte 0x$LAST"
if [ "$AFTER_BYTES" != "$((BEFORE_BYTES + 1))" ] || [ "$LAST" != 20 ]; then
    echo "FAIL a SPACE with no popup open did not reach the focused terminal"
    FAIL=1
fi
[ "$(sushin)" = 0 ] || { echo "FAIL a SPACE with no popup open opened a preview"; FAIL=1; }

echo "  P3c pointer over the DOCK ITSELF, no popup"
read -r DCX DCY <<< "$(stackcell 0 1)"
warp_or_die "$DCX" "$DCY"; sleep 0.5
want_focus zspace "P3c"
BEFORE_BYTES=$(bytes)
ydotool key 57:1 57:0
sleep 1.5
AFTER_BYTES=$(bytes)
echo "    bytes $BEFORE_BYTES -> $AFTER_BYTES"
if [ "$AFTER_BYTES" != "$((BEFORE_BYTES + 1))" ]; then
    echo "FAIL a SPACE over a stack CELL (no popup) did not reach the focused terminal"
    FAIL=1
fi
[ "$(sushin)" = 0 ] || { echo "FAIL hovering the cell itself previewed something"; FAIL=1; }

cp "$KEYS" "$OUT/keys.bin" 2>/dev/null
od -An -tx1 "$KEYS" > "$OUT/keys-hex.txt" 2>/dev/null

echo
[ $FAIL = 0 ] && echo "PASS v5_sushi_dock" || echo "FAIL v5_sushi_dock"
exit $FAIL
