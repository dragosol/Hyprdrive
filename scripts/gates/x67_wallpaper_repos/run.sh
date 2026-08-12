#!/usr/bin/env bash
# x67_wallpaper_repos -- a repository is a directory, the theme follows the
# picture, and the slideshow walks it.
#
#   P1 REPOS      a real git clone over file:// (2 wallpapers), a third pushed
#                 upstream and pulled down, the active repository switched
#                 through its SCHEMA ROW, and the repo removed again. No network
#                 and no credentials: file:// exercises the same clone and pull
#                 code path a github URL would, which is the whole of what this
#                 feature does with git.
#
#   P2 PALETTE    two swaps through the pane's own write path, graded on z10's
#                 arms rather than on pixels: matugen's primary moves, systemd's
#                 path unit starts theme-sync ON ITS OWN (the service's
#                 InvocationID changes and its log gains a line), and a DERIVED
#                 plugin key -- col_highlight -- is different afterwards. That
#                 chain is what "the theme follows the wallpaper" means; the
#                 pixel half of it is z10's claim and is not duplicated here.
#
#   P3 SLIDESHOW  mode and interval are schema rows. A tick inside the interval
#                 must do NOTHING (measured, not assumed -- a slideshow that
#                 ignores its interval is a slideshow that swaps every minute),
#                 and a tick past it must land on the PREDICTED next wallpaper:
#                 ordered means name order, so the gate computes the answer
#                 itself instead of accepting whatever came up.
#
#   P4 VIDEO      an mp4 generated on the spot: mpvpaper draws it, ii's config
#                 records one wallpaper path rather than two, the palette comes
#                 from a frame, and choosing a still stops mpvpaper. Skipped with
#                 a stated reason if this guest has no mpvpaper or no ffmpeg.
#
# THE WALLPAPER IS PUT BACK, palette and all, by the EXIT trap -- this is the
# second gate in the suite that moves it on purpose (z10 is the other) and every
# frame-diffing gate after it depends on that.
set -u
cd "$(dirname "$0")/../../.."
source scripts/lib/rig.sh
rig_env || exit 1

OUT=/mnt/host/zrig/phase12/x67; mkdir -p "$OUT"
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/hyprdrive
IICFG=$HOME/.config/illogical-impulse/config.json
PAL=${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/user/generated/colors.json
SYNCLOG=$STATE/theme-sync.log
SRC=/tmp/x67-wallsrc
BARE=/tmp/x67-wallsrc.git
CLONE=$HOME/Pictures/hyprdrive-wallpapers/x67
FAIL=0
bad() { echo "FAIL $*"; FAIL=1; }

gate_slate x67_wallpaper_repos >/dev/null 2>&1 || { echo "FAIL could not slate the session"; exit 1; }
# Standalone only -- under suite.sh the rotation is already held for the whole
# run and pausing again would replace that dead-man resume with a shorter one
# [z10_theme_adopt/run.sh].
[ "${RIG_HYPRWALL_HELD:-0}" = 1 ] || hyprwall_pause 60min

# ------------------------------------------------------------------ preflight --
for f in scripts/hdwall.py scripts/hdctl.py scripts/hyprwall-rotate.sh; do
    [ -f "$f" ] || { echo "FAIL preflight: this build has no $f -- there is no wallpaper layer to test"; exit 1; }
done
command -v matugen >/dev/null || { echo "FAIL preflight: no matugen in this guest"; exit 1; }
python3 scripts/hdwall.py status >/dev/null 2>&1 || { echo "FAIL preflight: hdwall cannot read its own settings"; exit 1; }

WALL0=$(jq -r '.background.wallpaperPath' "$IICFG")
REPO0=$(python3 scripts/hdctl.py get wallpaper.repo 2>/dev/null | head -1)
echo "preflight: wallpaper is $WALL0"
echo "preflight: mpvpaper $(command -v mpvpaper || echo ABSENT), ffmpeg $(command -v ffmpeg || echo ABSENT)"

x67_cleanup() {
    pkill -x mpvpaper >/dev/null 2>&1
    python3 scripts/hdctl.py set wallpaper.mode off >/dev/null 2>&1
    python3 scripts/hdwall.py slideshow >/dev/null 2>&1
    python3 scripts/hdwall.py repo-remove x67 --delete >/dev/null 2>&1
    python3 - <<'PY' >/dev/null 2>&1
import json, pathlib
p = pathlib.Path.home() / ".local/state/hyprdrive/settings.json"
if p.exists():
    d = json.loads(p.read_text()); d.get("panes", {}).pop("wallpaper", None)
    p.write_text(json.dumps(d, indent=1))
PY
    rm -rf "$SRC" "$BARE" "$CLONE"
    # Put the picture AND the palette back: this gate moved both on purpose.
    THEME=1 WALL="$WALL0" bash scripts/hyprwall-rotate.sh >/dev/null 2>&1
    sleep 3
    hyprctl reload >/dev/null 2>&1
}
trap 'x67_cleanup; hyprwall_resume' EXIT

# --------------------------------------------------------------------- P1 REPOS --
echo
echo "--- P1 REPOS: clone, pull, switch, remove"
rm -rf "$SRC" "$BARE" "$CLONE"
mkdir -p "$SRC"
cp /mnt/host/wallpapers/wp06.jpg /mnt/host/wallpapers/wp15.jpg "$SRC/"
git -C "$SRC" init -q -b main
git -C "$SRC" -c user.name=x67 -c user.email=x67@localhost add -A
git -C "$SRC" -c user.name=x67 -c user.email=x67@localhost commit -qm "two wallpapers"
git clone -q --bare "$SRC" "$BARE"

python3 scripts/hdwall.py repo-add x67 "file://$BARE" 2>&1 | sed 's/^/    /'
N=$(python3 scripts/hdwall.py list --repo x67 --json | python3 -c "import json,sys; print(len(json.load(sys.stdin)['wallpapers']))")
echo "    the clone has $N wallpapers"
[ "$N" = 2 ] || bad "P1: the clone landed $N wallpapers, wanted 2"
[ -d "$CLONE/.git" ] || bad "P1: $CLONE is not a git checkout"

cp /mnt/host/wallpapers/wp21.jpg "$SRC/"
git -C "$SRC" -c user.name=x67 -c user.email=x67@localhost add -A
git -C "$SRC" -c user.name=x67 -c user.email=x67@localhost commit -qm "a third"
git -C "$SRC" push -q "$BARE" main
python3 scripts/hdwall.py repo-pull x67 2>&1 | sed 's/^/    /'
N=$(python3 scripts/hdwall.py list --repo x67 --json | python3 -c "import json,sys; print(len(json.load(sys.stdin)['wallpapers']))")
[ "$N" = 3 ] || bad "P1: after a pull the clone has $N wallpapers, wanted 3"

python3 scripts/hdctl.py set wallpaper.repo x67 | sed 's/^/    /'
ACTIVE=$(python3 scripts/hdwall.py status --json | python3 -c "import json,sys; print(json.load(sys.stdin)['repo']['name'])")
echo "    the active repository is now '$ACTIVE' (set through its schema row)"
[ "$ACTIVE" = x67 ] || bad "P1: the schema row did not switch the repository ($ACTIVE)"

# ------------------------------------------------------------------- P2 PALETTE --
echo
echo "--- P2 PALETTE: two swaps, and somebody else has to react"
primary() { jq -r .primary "$PAL"; }
# `gradient data: ffecbd9f 0deg` on the plain form -- the second field is the
# word "data:", not the colour. The json form names its own type, which is the
# only shape that does not depend on how many words a type's label has.
highlight() { hyprctl getoption "$RIG_KEY:col_highlight" -j | python3 -c "import json,sys; print(json.load(sys.stdin)['gradient'])"; }

swap_and_watch() { # swap_and_watch NAME LABEL
    local name=$1 label=$2 n0 n1 inv0 inv1 i
    n0=$(wc -l < "$SYNCLOG" 2>/dev/null || echo 0)
    inv0=$(systemctl --user show hyprdrive-theme-sync.service -p InvocationID --value 2>/dev/null)
    python3 scripts/hdwall.py set "$name" 2>&1 | sed 's/^/    /'
    for i in $(seq 1 40); do
        n1=$(wc -l < "$SYNCLOG" 2>/dev/null || echo 0)
        [ "$n1" -gt "$n0" ] && break
        sleep 0.5
    done
    inv1=$(systemctl --user show hyprdrive-theme-sync.service -p InvocationID --value 2>/dev/null)
    [ "${n1:-0}" -gt "$n0" ] \
        && echo "    theme-sync ran on its own: $(tail -1 "$SYNCLOG")" \
        || bad "$label: theme-sync never ran -- nothing noticed the palette change"
    [ -n "$inv1" ] && [ "$inv1" != "$inv0" ] \
        || bad "$label: systemd did not start hyprdrive-theme-sync.service (invocation $inv0 -> ${inv1:-none})"
    sleep 2
}

swap_and_watch wp06 "P2 A"
A_PRIMARY=$(primary); A_HL=$(highlight)
echo "    A: primary=$A_PRIMARY col_highlight=$A_HL"
swap_and_watch wp15 "P2 B"
B_PRIMARY=$(primary); B_HL=$(highlight)
echo "    B: primary=$B_PRIMARY col_highlight=$B_HL"

[ "$A_PRIMARY" != "$B_PRIMARY" ] || bad "P2: the palette did not move between two different wallpapers ($A_PRIMARY)"
[ "$A_HL" != "$B_HL" ] || bad "P2: the derived plugin accent did not follow the palette ($A_HL)"
[ "$(jq -r '.background.wallpaperPath' "$IICFG")" = "$CLONE/wp15.jpg" ] \
    || bad "P2: ii's config does not point at the wallpaper that was set"

# ----------------------------------------------------------------- P3 SLIDESHOW --
echo
echo "--- P3 SLIDESHOW: the interval is obeyed, and the next one is predictable"
python3 scripts/hdctl.py set wallpaper.mode ordered | sed 's/^/    /'
python3 scripts/hdctl.py set wallpaper.interval 5 | sed 's/^/    /'
python3 scripts/hdwall.py slideshow | sed 's/^/    /'
systemctl --user is-active hyprdrive-slideshow.timer >/dev/null \
    && echo "    hyprdrive-slideshow.timer is active" \
    || bad "P3: the slideshow setting did not start the timer"

CUR=$(jq -r '.background.wallpaperPath' "$IICFG")
TOOSOON=$(python3 scripts/hdwall.py tick --verbose)
echo "    a tick inside the interval says: ${TOOSOON:-nothing}"
[ "$(jq -r '.background.wallpaperPath' "$IICFG")" = "$CUR" ] \
    || bad "P3: a tick inside the interval swapped the wallpaper anyway"
case "$TOOSOON" in *"to go"*) ;; *) bad "P3: the tick did not say why it declined" ;; esac

# Ordered means name order, so the answer is computable without asking hdwall.
WANT=$(python3 - "$CLONE" "$CUR" <<'PY'
import pathlib, sys
d, cur = pathlib.Path(sys.argv[1]), sys.argv[2]
files = sorted(str(f) for f in d.iterdir()
               if f.is_file() and f.suffix.lower() in (".jpg", ".jpeg", ".png", ".webp", ".mp4"))
i = files.index(cur) if cur in files else -1
print(files[(i + 1) % len(files)])
PY
)
python3 - <<'PY'
import json, pathlib, time
p = pathlib.Path.home() / ".local/state/hyprdrive/wallpapers.json"
d = json.loads(p.read_text()); d["last"] = 0
p.write_text(json.dumps(d, indent=1))
PY
python3 scripts/hdwall.py tick --verbose 2>&1 | sed 's/^/    /'
sleep 3
GOT=$(jq -r '.background.wallpaperPath' "$IICFG")
echo "    the slideshow advanced to $(basename "$GOT"), predicted $(basename "$WANT")"
[ "$GOT" = "$WANT" ] || bad "P3: ordered mode did not land on the next wallpaper by name"

python3 scripts/hdctl.py set wallpaper.mode off >/dev/null
python3 scripts/hdwall.py slideshow | sed 's/^/    /'
systemctl --user is-active hyprdrive-slideshow.timer >/dev/null \
    && bad "P3: turning the slideshow off left the timer running" \
    || echo "    off again, and the timer is stopped"

# --------------------------------------------------------------------- P4 VIDEO --
echo
echo "--- P4 VIDEO"
if ! command -v mpvpaper >/dev/null || ! command -v ffmpeg >/dev/null; then
    echo "    SKIPPED: this guest has no $(command -v mpvpaper >/dev/null || echo mpvpaper) $(command -v ffmpeg >/dev/null || echo ffmpeg)."
    echo "    The code path ships; nothing here measured it."
else
    ffmpeg -y -loglevel error -f lavfi \
        -i "color=c=0x1e5f8f:s=1280x720:d=4,drawbox=x=200:y=100:w=400:h=300:color=0xe08030@1:t=fill" \
        -pix_fmt yuv420p "$CLONE/x67motion.mp4" </dev/null || bad "P4: could not generate a test video"
    V_BEFORE=$(primary)
    python3 scripts/hdwall.py set x67motion 2>&1 | sed 's/^/    /'
    sleep 4
    V_AFTER=$(primary)
    echo "    primary $V_BEFORE -> $V_AFTER (derived from a frame of the video)"
    pgrep -x mpvpaper >/dev/null && echo "    mpvpaper is drawing it" || bad "P4: nothing is drawing the video"
    [ "$(jq -r '.background.wallpaperPath' "$IICFG")" = "$CLONE/x67motion.mp4" ] \
        || bad "P4: ii's config does not record the video as the wallpaper"
    [ "$V_BEFORE" != "$V_AFTER" ] || bad "P4: the palette did not follow the video"
    python3 scripts/hdwall.py set wp06 >/dev/null 2>&1
    sleep 2
    pgrep -x mpvpaper >/dev/null && bad "P4: mpvpaper kept drawing over a still wallpaper" \
        || echo "    choosing a still stopped mpvpaper"
fi

# --------------------------------------------------------------- P1 (remove) --
echo
python3 scripts/hdwall.py repo-remove x67 --delete 2>&1 | sed 's/^/    /'
python3 scripts/hdwall.py repos --json | grep -q '"x67"' && bad "P1: the repository is still listed after removal"
[ -d "$CLONE" ] && bad "P1: --delete left the clone on disk"
echo "    the repository is gone from the list and from disk"

alive_or_die "the whole run"
echo
[ $FAIL = 0 ] && echo "X67 PASS -- cloned, pulled, swapped with the palette following, walked in order, and put back" || echo "X67 FAIL"
exit $FAIL
