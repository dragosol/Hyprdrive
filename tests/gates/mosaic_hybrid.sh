#!/usr/bin/env bash
# mosaic_hybrid -- Mosaic drops to hybrid tiling when windows no longer fit and leaves it by itself when they fit again.
# Protects (designed behaviours, Hybrid tiling):
#   "Leaves by itself when the remembered pure sizes fit again (after closing or
#    resizing down); windows return to their pre-tiling size and shape [10-14,
#    10-15]. A short-lived window must not leave the desktop stuck in tiling [10-15]."
#   "Infinite canvas (off by default; when off, overflow goes to hybrid tiling) [10-26]"
#   "Never switches to real dwindle" -- the layout stays mosaic throughout.
# Asserts (layout mosaic, four 700x450 windows fit 1920x1080, five do not):
#   1. the fifth window: the desktop tiles -- the five cover the screen without
#      overlapping, inside it, and the four older ones are no longer 696x446
#   2. the fifth closed: the four are back at 696x446 at the very boxes they had
#      before it opened
#   3. a fifth that lives 0.3 s: 2 s later the four are again at those boxes
#   4. general:layout still mosaic
# Control (--control): mosaic:infinite_canvas = true (overflow spills onto the
# canvas instead) -- 1 fails. Recorded 2026-11-11 on 3ad1da3: control FAILS.
source "$(dirname "$0")/lib.sh"
gate_begin hyb
rig_start
cfg '{general={layout="mosaic"}}'
[ "$CONTROL" = 1 ] && cfg '{plugin={hyprdrive={mosaic={infinite_canvas=true}}}}'
go 1
for i in 1 2 3 4; do kexec m$i 700 450; sleep 0.5; done
settle 3 geom; PURE=$(geom)
check "pure: four at their own size" "$(is "$(echo "$PURE" | grep -o '696x446' | wc -l)" 4)" "$PURE"
kexec m5 700 450; sleep 0.8; settle 3 geom
tiled=$(J clients | jq -r '.[] | select(.workspace.id == 1) | "\(.class) \(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"' | python3 -I -c '
import sys
b = [l.split() for l in sys.stdin if l.strip()]; r = [list(map(int, x[1:])) for x in b]
inside = all(x >= 0 and y >= 0 and x + w <= 1920 and y + h <= 1080 for x, y, w, h in r)
ov = sum(1 for i in range(len(r)) for j in range(i + 1, len(r))
         if min(r[i][0]+r[i][2], r[j][0]+r[j][2]) - max(r[i][0], r[j][0]) > 0 and min(r[i][1]+r[i][3], r[j][1]+r[j][3]) - max(r[i][1], r[j][1]) > 0)
cover = sum(w * h for x, y, w, h in r) / (1900.0 * 1060)
old = sum(1 for x, s in zip(b, r) if x[0] != "m5" and (s[2], s[3]) == (696, 446))
print("n=%d inside=%d overlaps=%d cover=%.2f own_size_left=%d" % (len(r), inside, ov, cover, old))')
check "1: the fifth window tiles the desktop (inside, no overlap, covers it)" "$(echo "$tiled" | grep -qE 'n=5 inside=1 overlaps=0 cover=0\.(8[5-9]|9)' && echo 1)" "$tiled"
check "1: the older windows were tiled, not kept at their own size" "$(echo "$tiled" | grep -q 'own_size_left=0' && echo 1)" "$tiled"
close_win "$(addr_of m5)"; sleep 0.8; settle 3 geom
check "2: closed again: back to the pure sizes and boxes" "$(is "$(geom)" "$PURE")" "$(geom)"
kexec m6 700 450; sleep 0.3; close_win "$(addr_of m6)"; sleep 2; settle 3 geom
check "3: a short-lived window does not leave it stuck in tiling" "$(is "$(geom)" "$PURE")" "$(geom)"
check "4: the layout is still mosaic" "$(is "$(J getoption general:layout | jq -r .str)" mosaic)" "$(J getoption general:layout | jq -r .str)"
gate_end
