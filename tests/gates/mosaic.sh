#!/usr/bin/env bash
# mosaic -- pure Mosaic: opening never resizes the others, a centred cluster with theme gaps, remembered sizes, spawn at the pointer, quiet windows.
# Protects (designed behaviours, Mosaic):
#   "Opening a window NEVER resizes existing windows [10-14]. New windows open at
#    their remembered size, nearest the cursor [11-04]."
#   "Windows cluster organically, tight, centred on the screen, gaps = theme gaps
#    only [10-14..11-02]"
#   Focus and attention: "A window that opens unprompted does not take focus or
#    the cursor [11-05]"
# Asserts (layout mosaic, 1920x1080, gaps_in 5 + border 2 = 14 px between boxes):
#   1. four 700x450 windows opened one after another: no existing window's size
#      changes at any open; every one keeps its own size (696x446, kitty's cells)
#   2. the cluster's bounding box is centred on the screen (+-2 px) and every
#      window's nearest neighbour is exactly 14 px away
#   3. a window resized to 800x500 and closed reopens at 800x500 although it asks 500x300
#   4. a window opened by the compositor (exec) with the pointer top-left lands
#      left of and above the cluster's centre; pointer bottom-right: right and below
#   5. a window started from outside (unprompted, `hl.sh win`): the focus stays, and
#      the pointer stays on the focused window at the same spot on it (the window
#      may move; quiet_new_windows: "the pointer stays on your window")
# Control (--control): general:layout = dwindle on the same steps -- 1, 2 and 3
# fail. Recorded 2026-11-11 on 3ad1da3: control FAILS as it must.
source "$(dirname "$0")/lib.sh"
gate_begin mos
rig_start
if [ "$CONTROL" = 1 ]; then cfg '{general={layout="dwindle"}}'; else cfg '{general={layout="mosaic"}}'; fi
go 1
sizes() { J clients | jq -r '[.[] | select(.workspace.id == 1) | "\(.class)=\(.size[0])x\(.size[1])"] | sort | join(" ")'; }
resized=
for i in 1 2 3 4; do
    before=$(sizes); kexec m$i 700 450; sleep 0.6; settle 3 geom; after=$(sizes)
    for kv in $before; do echo " $after " | grep -q " $kv " || resized="$resized m$i:$kv->$(echo "$after" | tr ' ' '\n' | grep "^${kv%%=*}=")"; done
done
check "1: opening a window never resizes the others" "$(is "$resized" '')" "$resized"
check "1: each keeps its own size" "$(is "$(sizes)" 'm1=696x446 m2=696x446 m3=696x446 m4=696x446')" "$(sizes)"
lay=$(J clients | jq -r '.[] | select(.workspace.id == 1) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"' | python3 -I -c '
import sys
b = [list(map(int, l.split())) for l in sys.stdin if l.strip()]
x0 = min(r[0] for r in b); y0 = min(r[1] for r in b); x1 = max(r[0]+r[2] for r in b); y1 = max(r[1]+r[3] for r in b)
cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
def gap(a, c):  # gap between two boxes whose projections overlap on the other axis, else None
    ox = min(a[0]+a[2], c[0]+c[2]) - max(a[0], c[0]); oy = min(a[1]+a[3], c[1]+c[3]) - max(a[1], c[1])
    if oy > 0 and ox <= 0: return -ox
    if ox > 0 and oy <= 0: return -oy
    return None
near = []
for i, a in enumerate(b):
    g = [gap(a, c) for j, c in enumerate(b) if j != i]; g = [v for v in g if v is not None]
    near.append(min(g) if g else -1)
print("centre=%s gaps=%s" % ("ok" if abs(cx - 960) <= 2 and abs(cy - 540) <= 2 else "%.0f,%.0f" % (cx, cy), ",".join(map(str, near))))')
check "2: the cluster is centred on the screen" "$(echo "$lay" | grep -q 'centre=ok' && echo 1)" "$lay"
check "2: every window's nearest neighbour is 14 px away (theme gaps only)" "$(echo "$lay" | grep -qE 'gaps=14(,14)*$' && echo 1)" "$lay"
for i in 2 3 4; do close_win "$(addr_of m$i)"; done; sleep 1
kexec r 500 300; sleep 0.8; RA=$(addr_of r)
ev "hl.dispatch(hl.dsp.window.resize({ window = [[address:$RA]], x = 800, y = 500, relative = false }))"; sleep 1.2
close_win "$RA"; sleep 1.2; kexec r 500 300; sleep 1
check "3: a window reopens at its remembered size, not the one it asks" "$(is "$(win r '"\(.size[0])x\(.size[1])"')" '"800x500"')" "$(win r '"\(.size[0])x\(.size[1])"')"
close_win "$(addr_of r)"; kexec m2 700 450; sleep 1
side() { J clients | jq -r '.[] | select(.workspace.id == 1) | "\(.class) \(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"' | awk -v c="$1" '
    { cx[$1] = $2 + $4 / 2; cy[$1] = $3 + $5 / 2; if ($2 < x0 || NR == 1) x0 = $2; if ($3 < y0 || NR == 1) y0 = $3
      if ($2 + $4 > x1) x1 = $2 + $4; if ($3 + $5 > y1) y1 = $3 + $5 }
    END { mx = (x0 + x1) / 2; my = (y0 + y1) / 2; print (cx[c] < mx ? "L" : "R") (cy[c] < my ? "T" : "B") }'; }
$R ptr move 100 100 >/dev/null; sleep 0.3; kexec p1 400 300; sleep 0.8; S1=$(side p1)
close_win "$(addr_of p1)"; sleep 1
$R ptr move 1800 1000 >/dev/null; sleep 0.3; kexec p2 400 300; sleep 0.8; S2=$(side p2)
check "4: pointer top-left: the new window opens top-left of the cluster" "$(is "$S1" LT)" "$S1"
check "4: pointer bottom-right: it opens bottom-right" "$(is "$S2" RB)" "$S2"
close_win "$(addr_of p2)"; sleep 0.8
rel() { local c; c=$(hq cursorpos | tr -d ' '); win "$1" '"\(.at[0]) \(.at[1])"' | tr -d '"' | { read -r x y; echo "$(( ${c%,*} - x )),$(( ${c#*,} - y ))"; }; }
focus "$(addr_of m1)"; $R ptr move 900 500 >/dev/null; sleep 0.4
F0=$(J activewindow | jq -r .class); O0=$(rel m1)
kw quiet 500 300; sleep 1
check "5: an unprompted window does not take the focus" "$(is "$(J activewindow | jq -r .class)" "$F0")" "focus $(J activewindow | jq -r .class), was $F0"
check "5: and the pointer stays on your window (same spot on it)" "$(is "$(rel m1)" "$O0")" "pointer at $(rel m1) on m1, was $O0"
gate_end
