#!/usr/bin/env bash
# overview -- the overview leaves windows untouched, a tile click goes to the window, Super+F works in it, a Super+drag in the strip reorders desktops.
# Protects (designed behaviours, Overview, strip, dock; Focus and attention):
#   "Real windows [10-16, 11-06]" -- opening and closing it must leave every
#    window where it was (geometry AND pixels)
#   "Switching to a window from the dock previews or overview puts the cursor on
#    it, centred [10-29, 11-09]"
#   "Super+F works on an overview window in both trees [11-06]"
#   "Strip: Super+hover highlights and grows a desktop; drag to reorder [11-06]"
# Asserts (layout mosaic; a1, a2 on 1, b1 on 2):
#   1. overview opened and closed: every client's geometry is unchanged and a
#      settled screenshot matches the one taken before (largest differing blob
#      < 40 px -- the blink of a text cursor at most)
#   2. Super+F with the overview open, the pointer on the focused window's tile:
#      it goes fullscreen; again: back
#   2b. (owner, 2026-11-11: "super+f should act on the hovered tile in overview")
#      the pointer on the OTHER window's tile, Super+F: that one goes fullscreen,
#      the focused one is untouched; Super+F over it again: back on 1. The
#      pointer over no tile (a gap): the focused window goes fullscreen
#   2c. (owner, 2026-11-11: "yes") the same for Super+T (float, the overview stays
#      open and the window stays a tile), Super+P (pin), Super+Alt+F (maximize),
#      Super+Shift+3 (moved to 3 silently: the focus and the view stay, the tile
#      moves to 3's card), Omarchy's move (its bind names the ACTIVE window by
#      address), Super+H (minimize); each over no tile: the focused window
#      (lib.sh hover_actions)
#   3. a click on a2's tile (`hyprdrive:debug tile a2`): the overview closes, a2
#      has the focus, the pointer is on a2 -- at its centre (+-2 px) unless the
#      click point was on a2 already (then it stays: OverviewLifecycle.cpp handoff)
#   4. in the strip, desktop 2's card Super+dragged before desktop 1's: b1 is now
#      on 1, a1 and a2 on 2, and no two desktops share a number at any sample
# The strip's card positions are the rig's (1920x1080, scale 0.82, three cards):
# card 1 spans x 592..834 at y 145..280, card 2 starts ~840 -- there is no debug
# hook for cards (tile is for windows). If the strip layout changes, step 4
# fails with "nothing moved" and the coordinates need re-measuring (COVERAGE.md).
# Control (--control): a2 is resized by 20 px while the overview is open, the
# hovered tile's fullscreen is asked for the FOCUSED window by name (what Super+F
# did before the fix), and the card drag is done without Super -- 1 (geometry
# and pixels), 2b and 4 fail. Recorded 2026-11-11 on 3ad1da3: control FAILS as
# it must (2b and its control added and recorded the same day on the fix).
# 2c: --so <a4d6892 build> (Super+F/W only): every "over $H" check fails (the
# focused window is acted on); the "no target" ones pass on both.
source "$(dirname "$0")/lib.sh"
gate_begin ovw
rig_start
cfg '{general={layout="mosaic"}}'
ev 'hl.bind("SUPER + F", hl.dsp.window.fullscreen({ action = "toggle" }))'
go 2; kw b1 700 450; go 1; kw a1 700 450; kw a2 600 400; sleep 0.5
$R ptr move 700 1000 >/dev/null; settle 3 geom; G0=$(geom); shot "$GOUT/before.png"
$R overview >/dev/null; sleep 1.2
[ "$CONTROL" = 1 ] && ev "hl.dispatch(hl.dsp.window.resize({ window = [[address:$(addr_of a2)]], x = 20, y = 0, relative = true }))"
$R overview >/dev/null; sleep 1.2; settle 3 geom; shot "$GOUT/after.png"
check "1: overview open/close: geometry untouched" "$(is "$(geom)" "$G0")" "$(geom)"
pd=$(pixdiff "$GOUT/before.png" "$GOUT/after.png"); set -- $pd
check "1: overview open/close: pixels untouched (largest blob < 40 px)" "$([ "${2:-99999}" -lt 40 ] 2>/dev/null && echo 1)" "differing px, largest blob: $pd"

$R overview >/dev/null; sleep 1.2
# the pointer on the focused window's tile: since 2b's ruling Super+F acts on
# the tile under the pointer, and 700,1000 is b1's on desktop 2's card
tile_of() { dbg tile "$1" | grep -o "tile $1 [0-9 -]*" | awk '{print $3, $4, $5, $6}'; }
F=$(J activewindow | jq -r .class); TF=$(tile_of "$F")
[ -n "$TF" ] && { set -- $TF; $R ptr move $(( $1 + $3 / 2 )) $(( $2 + $4 / 2 )) >/dev/null; sleep 0.4; }
$R tap Super+F >/dev/null; sleep 1.5
check "2: Super+F in the overview: the focused window goes fullscreen" "$(is "$(win "$F" .fullscreen)" 2)" "$F fullscreen=$(win "$F" .fullscreen)"
$R tap Super+F >/dev/null; sleep 1.8
check "2: Super+F again: back where it was" "$(is "$(win "$F" .fullscreen) $(win "$F" .workspace.id)" "0 1")" "$F fullscreen=$(win "$F" .fullscreen) on $(win "$F" .workspace.id)"
# 2b. Super+F acts on the HOVERED tile (owner, 2026-11-11: "super+f should act
# on the hovered tile in overview"); over no tile, on the focused window.
H=$([ "$F" = a1 ] && echo a2 || echo a1)
TH=$(tile_of "$H"); TF=$(tile_of "$F")
if [ -n "$TH" ] && [ -n "$TF" ]; then
    set -- $TH; $R ptr move $(( $1 + $3 / 2 )) $(( $2 + $4 / 2 )) >/dev/null; sleep 0.4
    if [ "$CONTROL" = 1 ]; then ev "hl.dispatch(hl.dsp.window.fullscreen({ window = [[address:$(addr_of "$F")]], action = \"toggle\" }))"
    else $R tap Super+F >/dev/null; fi
    sleep 1.5
    check "2b: Super+F over $H's tile ($F focused): $H goes fullscreen" "$(is "$(win "$H" .fullscreen)" 2)" "$H fullscreen=$(win "$H" .fullscreen)"
    check "2b: ... and $F is untouched" "$(is "$(win "$F" '"\(.fullscreen) \(.workspace.id)"')" '"0 1"')" "$F $(win "$F" '"\(.fullscreen) \(.workspace.id)"')"
    # back, the same way: Super+F over its tile (it is on its own desktop's card now)
    TH=$(tile_of "$H")
    if [ -n "$TH" ]; then set -- $TH; $R ptr move $(( $1 + $3 / 2 )) $(( $2 + $4 / 2 )) >/dev/null; sleep 0.4; $R tap Super+F >/dev/null
    else fs "$(addr_of "$H")" unset; fi
    wait_for 3 "[ \"\$(win $H .workspace.id) \$(win $H .fullscreen)\" = '1 0' ]"; settle 3 geom
    check "2b: Super+F over it again: $H is back on 1" "$(is "$(win "$H" '"\(.fullscreen) \(.workspace.id)"')" '"0 1"')" "$H $(win "$H" '"\(.fullscreen) \(.workspace.id)"')"
    # over no tile (the gap under the shorter of the two): the focused window
    focus "$(addr_of "$F")"; sleep 0.3
    TH=$(tile_of "$H"); TF=$(tile_of "$F"); set -- $TH $TF
    if [ $(( $2 + $4 )) -lt $(( $6 + $8 )) ]; then GX=$(( $1 + $3 / 2 )); GY=$(( $2 + $4 + ($6 + $8 - $2 - $4) / 2 ))
    else GX=$(( $5 + $7 / 2 )); GY=$(( $6 + $8 + ($2 + $4 - $6 - $8) / 2 )); fi
    $R ptr move $GX $GY >/dev/null; sleep 0.4; FOC=$(J activewindow | jq -r .class)
    $R tap Super+F >/dev/null; sleep 1.5
    check "2b: Super+F over no tile ($GX,$GY): the focused window ($FOC) goes fullscreen" "$(is "$(win "$FOC" .fullscreen)" 2)" "$(geom)"
    fs "$(addr_of "$FOC")" unset; wait_for 3 "[ \"\$(win $FOC .workspace.id) \$(win $FOC .fullscreen)\" = '1 0' ]"; settle 3 geom
else
    check "2b: debug tile answers for a1 and a2" 0 "$(dbg tile a1 | tail -1) / $(dbg tile a2 | tail -1)"
fi

# 2c. (owner, 2026-11-11: "yes" -- the other Super+key actions follow the hover
# target too) Super+T, Super+P, Super+Alt+F, Super+Shift+3, Omarchy's move,
# Super+H over the other window's tile: that one; over no tile: the focused one.
hst() { J clients | jq -r ".[] | select(.class == \"$1\") | \"\(.workspace.id) f\(if .floating then 1 else 0 end) p\(if .pinned then 1 else 0 end) fs\(.fullscreen)\"" | head -1; }
had() { addr_of "$1"; }
hov() { local t; t=$(tile_of "$1"); [ -n "$t" ] || return 1; set -- $t; $R ptr move $(( $1 + $3 / 2 )) $(( $2 + $4 / 2 )) >/dev/null; sleep 0.4; }
nohov() { $R ptr move 3 540 >/dev/null; sleep 0.4; }   # the overview's left edge: no tile
hover_binds
H=$([ "$F" = a1 ] && echo a2 || echo a1)
HOVER_OPEN=1 hover_actions 2c hov nohov "$H" "$F"
$R ptr move 700 1000 >/dev/null; sleep 0.3

T=$(dbg tile a2 | grep -o 'tile a2 [0-9 ]*'); set -- $T
if [ $# -ge 6 ]; then
    PX=$(( $3 + $5 / 2 )); PY=$(( $4 + $6 / 2 )); $R ptr tap $PX $PY >/dev/null; sleep 1.5
    BOX=$(J clients | jq -r '.[] | select(.class == "a2") | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"'); CP=$(hq cursorpos | tr -d ' ')
    check "3: tile click: a2 focused" "$(is "$(J activewindow | jq -r .class)" a2)" "focus $(J activewindow | jq -r .class)"
    check "3: tile click: the overview closed" "$(dbg gesture state | grep -q ' 0 overview' && echo 1)" "$(dbg gesture state | grep -o '[0-9]* overview.*')"
    # OverviewLifecycle.cpp handoff: the pointer goes to the window's centre unless
    # the click point already lies on the window (a dock preview click always centres)
    check "3: tile click: the pointer is on a2, centred unless it was on it already" "$(python3 -I -c "
x, y, w, h = map(int, '$BOX'.split()); px, py = map(int, '$CP'.split(','))
on = lambda a, b: x <= a < x + w and y <= b < y + h
print(1 if on(px, py) and (on($PX, $PY) and abs(px - $PX) <= 2 and abs(py - $PY) <= 2 or abs(px - (x + w // 2)) <= 2 and abs(py - (y + h // 2)) <= 2) else 0)")" "pointer $CP, clicked $PX,$PY, a2 at $BOX"
else
    check "3: debug tile a2 answers in the overview" 0 "$(dbg tile a2 | tail -1)"
fi

settle 3 geom; $R overview >/dev/null; sleep 1.2
sampler_start ids sample_ids
if [ "$CONTROL" = 1 ]; then $R ptr drag 880 165 620 165 30 300 >/dev/null
else $R down Super >/dev/null; $R ptr drag 880 165 620 165 30 300 >/dev/null; $R up Super >/dev/null; fi
sleep 1.5; n=$(sampler_stop ids)
check "4: strip Super+drag: desktop 2 is now 1 (b1 on 1, a1 a2 on 2)" "$(is "$(win b1 .workspace.id)$(win a1 .workspace.id)$(win a2 .workspace.id)" 122)" "b1/a1/a2 on $(win b1 .workspace.id)/$(win a1 .workspace.id)/$(win a2 .workspace.id), $(ids)"
check "4: no duplicate desktop number at any of $n samples" "$(is "$(grep -c DUP "$GOUT/ids.samp")" 0)" "$(grep -m1 DUP "$GOUT/ids.samp")"
$R overview >/dev/null; sleep 0.8
gate_end
