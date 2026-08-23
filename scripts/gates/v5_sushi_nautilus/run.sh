#!/usr/bin/env bash
# v5_sushi_nautilus -- V11 SPEC V5, the OTHER half: spacebar sushi from
# Nautilus, and the house presentation the previewer window gets when it lands.
#
# V5 asks two separate things of this arm and they are graded separately:
#
#   1. THAT IT WORKS AT ALL in this session. Mind the package name --
#      on Fedora the package is `sushi` and `gnome-sushi` resolves to nothing, so
#      before this work there was no previewer in the guest and SPACE in
#      Nautilus did nothing whatever. That is this gate's fail-on-old, and it
#      is a real one rather than a build difference: the arm cannot pass on a
#      machine where the previewer is absent, and the first thing it does is
#      say so by name.
#
#   2. THAT IT IS DRESSED. config/hyprdrive/25-rules.lua is the fragment layer's
#      answer for a window the plugin causes but does not own: float, centre,
#      blur allowed, and an opacity for the blur to show through. The rules are
#      asserted twice -- that the SHIPPED fragment still carries them (a future
#      edit that drops one reds here rather than silently un-frosting previews),
#      and that the window they describe is the window that actually maps.
#
# THE FROST MEASUREMENT IS THE INTERESTING ONE. Standing user law is that frost
# is on by default on every surface, and an OPAQUE app defeats compositor blur
# outright -- so "is it frosted" is not a question about the picture, it is a
# question about whether switching the blur pass off changes this window. Three
# frames, controls on both sides: blur on, blur OFF, blur on again. The window
# must change both ways, a patch of bare wallpaper must not change at all, and
# the two blur-on frames must agree -- which also makes a frozen capture an
# explicit failure instead of a suspiciously quiet pass. The threshold is 3 and
# not the usual 26 for a reason the grader spells out: at 0.92 opacity the whole
# effect is eight percent of the backdrop's blur, a maximum delta of 14 measured
# on the guest, and DEV=26 would call a correctly frosted window opaque.
#
# The pointer is parked away from everything for the whole run, so this is also
# a third pass-through proof: with no stack popup open the plugin claims nothing
# and the SPACE arrives at Nautilus, which is the only reason any of this
# happens.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=${RIG_EVIDENCE:-/mnt/host/zrig}/v5/nautilus; mkdir -p "$OUT"
rm -f "$OUT"/*.png "$OUT"/*.txt
FAIL=0
GRADE=scripts/v5_sushi_gate.py
FRAG=config/hyprdrive/25-rules.lua

# ------------------------------------------------------------ the blockers --
if [ ! -x /usr/libexec/org.gnome.NautilusPreviewer ]; then
    echo "FAIL no previewer at /usr/libexec/org.gnome.NautilusPreviewer"
    echo "     Fedora ships it in the package \`sushi\` -- \`gnome-sushi\` does not exist there."
    exit 1
fi
command -v nautilus >/dev/null 2>&1 || { echo "FAIL nautilus is not installed in this guest"; exit 1; }

# --------------------------------------------------- the shipped rules ------
echo "--- P0 FRAGMENT: the shipped window rules still say what they must"
for want in float center no_blur opacity; do
    if grep -Eq "window_rule.*[{,] *$want *=" "$FRAG" 2>/dev/null; then
        echo "    $FRAG carries a $want rule"
    else
        echo "FAIL $FRAG no longer carries a $want rule -- previews lose the house presentation"
        FAIL=1
    fi
done
grep -qF 'org\.gnome\.NautilusPreviewer' "$FRAG" 2>/dev/null \
    || { echo "FAIL $FRAG does not match the previewer's class"; FAIL=1; }

gate_slate v5_sushi_nautilus >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }
[ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_pause 30min

WORK=$(mktemp -d /tmp/v5naut.XXXXXXXX) || { echo "FAIL no fixture root"; exit 1; }
case "$WORK" in
    /tmp/v5naut.*) ;;
    *) echo "FAIL fixture root '$WORK' is not under /tmp/v5naut. -- refusing to run"; exit 1 ;;
esac
DIR=$WORK/dir
mkdir -p "$DIR"
# EXACTLY ONE FILE, so Ctrl+A is an unambiguous selection of a known name and
# the gate never has to aim a click at an icon whose position it guessed.
python3 - "$DIR" <<'PY'
import pathlib, sys
from PIL import Image
im = Image.new("RGB", (560, 420))
px = im.load()
for x in range(560):
    for y in range(420):
        px[x, y] = ((x * 4) % 256, (y * 6) % 256, (x + 2 * y) % 256)
im.save(pathlib.Path(sys.argv[1]) / "onlyfile.png")
PY
ONLY=onlyfile.png

closep() { timeout 10 busctl --user call org.gnome.NautilusPreviewer /org/gnome/NautilusPreviewer \
                   org.gnome.NautilusPreviewer2 Close >/dev/null 2>&1; }

cleanup() {
    closep
    hyprctl eval 'hl.config({decoration={blur={enabled=true}}}) return 0' >/dev/null 2>&1
    systemctl --user stop v5-blur-restore.timer 2>/dev/null
    pkill -f "nautilus $DIR" 2>/dev/null
    case "${WORK:-}" in /tmp/v5naut.*) rm -rf "$WORK" ;; esac
    ov off
    headless_off
    hyprwall_resume
}
trap cleanup EXIT

headless_on || exit 1

sushin() { hyprctl clients -j | python3 -c "
import json,sys
print(sum(1 for c in json.load(sys.stdin) if c['class']=='org.gnome.NautilusPreviewer'))"; }
sushi1() { hyprctl clients -j | python3 -c "
import json,sys
cs=[c for c in json.load(sys.stdin) if c['class']=='org.gnome.NautilusPreviewer']
print('%s %d %d %d %d %s' % ((cs[0]['title'],)+tuple(cs[0]['at'])+tuple(cs[0]['size'])+(cs[0]['floating'],)) if cs else 'NONE 0 0 0 0 False')"; }
shoot() { grim -o "$RIG_MON" "$OUT/$1.png" >/dev/null 2>&1; sleep 0.3; }

closep; sleep 1.0
[ "$(sushin)" = 0 ] || { echo "FAIL a previewer window was already up before the gate started"; FAIL=1; }

# ============================================================ P1  THE SPACEBAR ==
echo "--- P1 NAUTILUS: open the fixture folder, select its one file, SPACE"
pkill -x nautilus 2>/dev/null; sleep 1.0
setsid nautilus "$DIR" >/dev/null 2>&1 &
NAUT=0
for _ in $(seq 1 30); do
    if [ "$(hyprctl clients -j | python3 -c "
import json,sys
print(sum(1 for c in json.load(sys.stdin) if c['class']=='org.gnome.Nautilus'))")" -ge 1 ]; then NAUT=1; break; fi
    sleep 1
done
[ $NAUT = 1 ] || { echo "FAIL nautilus never mapped a window"; FAIL=1; }
sleep 3

# The pointer goes to a corner and STAYS there: nothing in this gate is a
# pointer gesture, and a pointer resting over a dock cell or a window is one
# more thing that could explain a result.
warp_or_die 60 60; sleep 0.4
dsp 'hl.dsp.focus({window = [[class:org.gnome.Nautilus]]})'; sleep 1.0
shoot p1-nautilus

ydotool key 29:1 30:1 30:0 29:0        # CTRL+A, select the one file
sleep 1.5
shoot p1-selected

ydotool key 57:1 57:0                  # SPACE
sleep 4.0
shoot p1-preview

N=$(sushin)
read -r TITLE SX SY SW SH SFLOAT <<< "$(sushi1)"
echo "    previewer clients: $N   title '$TITLE'  at $SX,$SY  ${SW}x$SH  floating $SFLOAT"
if [ "$N" != 1 ]; then
    echo "FAIL SPACE in Nautilus produced $N previewer windows, wanted 1"
    echo "     (this is the arm that reds when sushi is not installed at all)"
    FAIL=1
    exit $FAIL
fi
[ "$TITLE" = "$ONLY" ] || { echo "FAIL the preview is of '$TITLE', not of the selected file '$ONLY'"; FAIL=1; }
[ "$SW" -gt 0 ] && [ "$SH" -gt 0 ] || { echo "FAIL the preview window has no size"; FAIL=1; }

# ========================================================= P2  THE PRESENTATION ==
echo "--- P2 PRESENTATION: floating, centred on the output"
CX=$((SX + SW / 2)); CY=$((SY + SH / 2))
WANTX=$((RIG_W / 2)); WANTY=$((RIG_H / 2))
DX=$((CX - WANTX)); DY=$((CY - WANTY))
[ "$DX" -lt 0 ] && DX=$((-DX)); [ "$DY" -lt 0 ] && DY=$((-DY))
echo "    window centre $CX,$CY   output centre $WANTX,$WANTY   off by $DX,$DY (tolerance 24)"
[ "$SFLOAT" = True ] || { echo "FAIL the preview did not float"; FAIL=1; }
if [ "$DX" -gt 24 ] || [ "$DY" -gt 24 ]; then
    echo "FAIL the preview is not centred on the output"
    FAIL=1
fi

# ================================================================ P3  THE FROST ==
echo "--- P3 FROST: switching the blur pass off must change this window"
# BLUR IS A HYPRLAND KEY, not a plugin one, so gate_slate's baseline does not
# restore it -- a gate that died with the blur pass off would leave every frost
# gate after it in the suite measuring an unfrosted desktop. The trap puts it
# back; this is the dead man for the case where no trap runs, on hyprwall's own
# pattern (named unit, last caller wins, and it needs the instance signature
# because it will be talking to hyprctl from outside this shell).
systemctl --user stop v5-blur-restore.timer 2>/dev/null
systemd-run --user --on-active=3min --unit=v5-blur-restore \
    -E "HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE" \
    hyprctl eval 'hl.config({decoration={blur={enabled=true}}}) return 0' >/dev/null 2>&1

shoot p3-A1-bluron
hyprctl eval 'hl.config({decoration={blur={enabled=false}}}) return 0' >/dev/null 2>&1
sleep 1.5
shoot p3-B-bluroff
hyprctl eval 'hl.config({decoration={blur={enabled=true}}}) return 0' >/dev/null 2>&1
sleep 1.5
shoot p3-A2-bluron
systemctl --user stop v5-blur-restore.timer 2>/dev/null

BLURON=$(hyprctl getoption decoration:blur:enabled -j 2>/dev/null | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('bool'))
except Exception: print('?')")
echo "    decoration:blur:enabled is back at $BLURON (True wanted)"
[ "$BLURON" = True ] || { echo "FAIL the gate left the blur pass off -- every frost verdict after this one is void"; FAIL=1; }

# The OUT control is bare wallpaper on the right of the output: clear of the
# preview (centred), of the Nautilus window (also centred), of the dock and of
# the shell's clock widget. If blur off changes THAT, the frames are not
# comparable and no verdict below them means anything.
OUTX=$((RIG_W - 660)); OUTY=$((RIG_H / 2 - 100))
python3 "$GRADE" frost "$OUT/p3-A1-bluron.png" "$OUT/p3-B-bluroff.png" "$OUT/p3-A2-bluron.png" \
        $((SX + 8)) $((SY + 8)) $((SW - 16)) $((SH - 16)) "$OUTX" "$OUTY" 300 300 || FAIL=1

# ============================================================== P4  THE TOGGLE ==
echo "--- P4 TOGGLE: SPACE again in Nautilus takes the preview away"
dsp 'hl.dsp.focus({window = [[class:org.gnome.Nautilus]]})'; sleep 1.0
ydotool key 57:1 57:0
sleep 3.0
shoot p4-closed
N=$(sushin)
echo "    previewer clients after the second SPACE: $N"
[ "$N" = 0 ] || { echo "FAIL the second SPACE did not close the preview"; FAIL=1; }

echo
[ $FAIL = 0 ] && echo "PASS v5_sushi_nautilus" || echo "FAIL v5_sushi_nautilus"
exit $FAIL
