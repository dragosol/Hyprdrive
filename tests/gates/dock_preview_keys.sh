#!/usr/bin/env bash
# dock_preview_keys -- Super+F and Super+W act on the dock preview under the pointer, as on a hovered overview tile.
# Protects (designed behaviours, Overview, strip, dock):
#   "if I mouseover a window preview in the dock I should have access to all
#    the same super+keybind functionality as I do in overview when I'm
#    mousedover that window" [11-11]
# Two windows of one app, pA (focused) and pB, on desktop 1; the dock shown
# (autohide off); the user's binds are Lua's, as Omarchy's are: SUPER+F
# fullscreen toggle, SUPER+W close. The pointer goes to the app's icon (from
# `hyprdrive:debug dockmenu`), the hover pane opens, then onto a cell.
# Asserts:
#   1. Super held over pB's cell: the pane stays up (no grace dismissal)
#   2. Super+F over pB's cell: pB goes fullscreen (its own desktop), pA untouched
#   3. Super+F again (the pointer on pB's cell): pB is back on 1, not fullscreen
#   4. the pointer on the pane but in the gap between the cells, pA focused:
#      Super+F fullscreens pA (the focused window, as without the pane), pB untouched
#   4b. (owner, 2026-11-11: "yes") the same for Super+T (float), Super+P (pin),
#      Super+Alt+F (maximize), Super+Shift+3 (moved to 3 silently), Omarchy's move
#      (its bind names the ACTIVE window by address), Super+H (minimize; over a
#      minimized window's preview: restored); each with the pointer on no
#      preview: pA (lib.sh hover_actions)
#   5. Super+W over pB's cell: pB closes, pA stays, the pane shows pA's cell only
#   6. `hyprdrive:window close` over pA's cell (the last): pA closes, the pane is gone
# Control (--control --control-so <e8e89e7's build: the dockmenu icons, not the
# feature>): 2 fails (pA goes fullscreen), 5 fails (pA closes). 4b: --so <a4d6892
# build>: every "over pB" check fails, the "no target" ones pass.
source "$(dirname "$0")/lib.sh"
gate_begin dpk
control_build "a build without the dock-preview hover target (e8e89e7)"
rig_start
cfg '{plugin={hyprdrive={dock={autohide=false}}}}'
ev 'hl.bind("SUPER + F", hl.dsp.window.fullscreen({ action = "toggle" }))'
ev 'hl.bind("SUPER + W", hl.dsp.window.close())'
# titled kitties running sleep: no shell retitles them, so each cell is named
kt() {
    local n0; n0=$(nclients)
    $R win kitty -o remember_window_size=no -o initial_window_width=900 -o initial_window_height=600 --class app --title "$1" sleep 100000 >/dev/null
    wait_for 5 "[ \$(nclients) -gt $n0 ]" || echo "warn: $1 never mapped"
}
kt pB; kt pA; sleep 0.8
A=$(J clients | jq -r '.[] | select(.title == "pA") | .address'); B=$(J clients | jq -r '.[] | select(.title == "pB") | .address')
focus "$A"; sleep 0.3
st() { J clients | jq -r ".[] | select(.title == \"$1\") | \"\(.workspace.id) \(.fullscreen)\""; }
dm() { dbg dockmenu | sed 's/^.*dockmenu:/dockmenu:/'; }
centre() { set -- $(echo "$1" | tr ',x' '  '); echo "$(( $1 + $3 / 2 )) $(( $2 + $4 / 2 ))"; }
cell() { dm | grep "cell \"$1\"" | grep -o '[-0-9]*,[-0-9]* [0-9]*x[0-9]*' | head -1; }
ICON=$(dm | grep -o 'icon app [-0-9,]* [0-9x]*' | awk '{print $3, $4}')
[ -n "$ICON" ] || { check "dockmenu reports the app's icon" 0 "$(dm | tr '\n' ' ')"; gate_end; }
# onto the icon, then up onto a cell: one pointer path, as a hand would
hover_cell() {
    $R ptr move $(centre "$ICON") >/dev/null; sleep 0.6
    local c; c=$(cell "$1"); [ -n "$c" ] || return 1
    $R ptr move $(centre "$c") >/dev/null; sleep 0.4
}

# 1. Super held over pB's cell: the pane stays up past its grace
hover_cell pB || check "the pane opens with pB's cell" 0 "$(dm | tr '\n' ' ')"
$R down Super >/dev/null; sleep 0.6; P=$(dm | head -1); $R up Super >/dev/null
check "1: Super held over pB's cell: the pane stays up" "$(echo "$P" | grep -q 'pane .*' && ! echo "$P" | grep -q '(out)' && echo 1)" "$P"

# 2. Super+F over pB's cell: pB fullscreen, pA untouched
$R tap Super+F >/dev/null
wait_for 3 "[ \"\$(st pB | cut -d' ' -f2)\" = 2 ] || [ \"\$(st pA | cut -d' ' -f2)\" = 2 ]"; sleep 1
check "2: Super+F over pB's cell: pB goes fullscreen" "$(is "$(st pB | cut -d' ' -f2)" 2)" "pB $(st pB), pA $(st pA)"
check "2: ... and pA is untouched (desktop 1, not fullscreen)" "$(is "$(st pA)" "1 0")" "pA $(st pA)"

# 3. again, the pointer on pB's cell: back
C=$(cell pB); [ -n "$C" ] && { $R ptr move $(centre "$C") >/dev/null; sleep 0.4; }
$R tap Super+F >/dev/null
wait_for 3 "[ \"\$(st pB)\" = '1 0' ]"; settle 3 geom
check "3: Super+F again: pB is back on 1, not fullscreen" "$(is "$(st pB)" "1 0")" "pB $(st pB)"
[ "$(st pA)" = "1 0" ] || fs "$A" unset
[ "$(st pB)" = "1 0" ] || fs "$B" unset
settle 3 geom

# 4. the pointer on the pane, between the cells: the focused window, as ever
focus "$A"; sleep 0.3
hover_cell pB
CA=$(cell pA); CB=$(cell pB)
if [ -n "$CA" ] && [ -n "$CB" ]; then
    set -- $(echo "$CB $CA" | tr ',x' '  ')
    if [ "$1" -lt "$5" ]; then GX=$(( ($1 + $3 + $5) / 2 )); else GX=$(( ($5 + $7 + $1) / 2 )); fi
    GY=$(( $2 + $4 / 2 ))
    $R ptr move $GX $GY >/dev/null; sleep 0.4
    FOC=$(J activewindow | jq -r .title); PANE=$(dm | head -1)
    $R tap Super+F >/dev/null; wait_for 3 "[ \"\$(st pA | cut -d' ' -f2)\" = 2 ] || [ \"\$(st pB | cut -d' ' -f2)\" = 2 ]"; sleep 1
    check "4: Super+F between the cells ($GX,$GY; $FOC focused): pA goes fullscreen" "$(is "$FOC $(st pA | cut -d' ' -f2)" "pA 2")" "focus $FOC, pA $(st pA), pB $(st pB); $PANE"
    check "4: ... and pB is untouched" "$(is "$(st pB)" "1 0")" "pB $(st pB)"
    fs "$A" unset; wait_for 3 "[ \"\$(st pA)\" = '1 0' ]"; settle 3 geom
else
    check "4: the pane shows both cells" 0 "$(dm | tr '\n' ' ')"
fi

# 4b. (owner, 2026-11-11: "yes") the other Super+key actions over pB's cell:
# pB; with the pointer on no preview: pA (lib.sh hover_actions)
hst() { J clients | jq -r ".[] | select(.title == \"$1\") | \"\(.workspace.id) f\(if .floating then 1 else 0 end) p\(if .pinned then 1 else 0 end) fs\(.fullscreen)\"" | head -1; }
had() { J clients | jq -r ".[] | select(.title == \"$1\") | .address" | head -1; }
nohov() { $R ptr move 900 300 >/dev/null; sleep 0.8; }   # off the dock: the pane goes
hover_binds
hover_actions 4b hover_cell nohov pB pA
# Super+H over a MINIMIZED window's preview brings it back
focus "$A"; sleep 0.3; hover_cell pB; $R tap Super+H >/dev/null; wait_for 3 "[ \"\$(hst pB | cut -d' ' -f1)\" -lt 0 ]"; sleep 0.8
hover_cell pB; $R tap Super+H >/dev/null; wait_for 3 "[ \"\$(hst pB | cut -d' ' -f1)\" = 1 ]"; sleep 0.8
check "4b H: Super+H over pB's preview while it is minimized: back on 1" "$(is "$(hst pB | cut -d' ' -f1)" 1)" "pB $(hst pB)"
focus "$A"; sleep 0.3

# 5. Super+W over pB's cell: pB closes, pA stays, one cell left
focus "$A"; sleep 0.3
hover_cell pB
$R tap Super+W >/dev/null
wait_for 3 "[ \$(nclients) -lt 2 ]"; sleep 0.8
check "5: Super+W over pB's cell: pB closes" "$(is "$(J clients | jq -r '[.[] | .title] | sort | join(",")')" pA)" "clients: $(J clients | jq -r '[.[] | .title] | join(",")')"
D=$(dm)
check "5: ... the pane shows pA's cell only" "$(is "$(echo "$D" | grep -c '^ cell ')$(echo "$D" | grep -c 'cell "pA"')" 11)" "$(echo "$D" | head -3 | tr '\n' ' ')"

# 6. the window dispatcher over the last cell: it closes, the pane goes
C=$(cell pA)
if [ -n "$C" ]; then
    $R ptr move $(centre "$C") >/dev/null; sleep 0.4
    hq dispatch 'hl.plugin.hyprdrive.window("close")' >/dev/null 2>&1
    wait_for 3 "[ \$(nclients) -eq 0 ]"; sleep 1
    check "6: window close over pA's cell: pA closes" "$(is "$(nclients)" 0)" "clients: $(J clients | jq -r '[.[] | .title] | join(",")')"
    check "6: ... and the pane is gone" "$(dm | head -1 | grep -q 'no pane' && echo 1)" "$(dm | head -1)"
else
    check "6: the pane shows pA's cell" 0 "$(dm | tr '\n' ' ')"
fi
gate_end
