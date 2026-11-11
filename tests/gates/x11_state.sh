#!/usr/bin/env bash
# x11_state -- an X11 client insisting on maximized gets it ONCE, and user maximize/fullscreen work during a storm block.
# Protects: fix 3558972 ("XGeometry.hpp, A GAME FLIPPING MAXIMIZED"), the owner's
# Wine games; designed behaviours, Fullscreen [10-30, 10-19]: games are
# fullscreen apps the user must still be able to toggle. tests/rig/xstate/README.md.
# Asserts (tests/rig/xstate/wine_state.c, class wine_state.exe, 800x600):
#   A. `max` mode (re-asks MAXIMIZED on every state/configure change): over 8 s
#      Hyprland's fullscreen/fullscreenClient pair changes at most ONCE (-> 1 1),
#      _NET_WM_STATE shows MAXIMIZED_VERT and MAXIMIZED_HORZ, the client sends no
#      request after its first second
#   B. `flap` mode (asks the opposite of the FULLSCREEN it reads, forever): it is
#      blocked (xgeom storms>=1), and during the block four user fullscreen
#      toggles on it each change it, and four maximize toggles on a kitty each work
# Control: --so 8bb258c (scratchpad p3t/old.so): A flips 0<->1 for the whole run,
# xprop never shows MAXIMIZED; B's toggles do nothing. Recorded 2026-11-11: FAILS.
source "$(dirname "$0")/lib.sh"
gate_begin x11
cc -O2 -o "$GOUT/wine_state" "$ROOT/tests/rig/xstate/wine_state.c" $(pkg-config --cflags --libs xcb) || skip "cannot build wine_state (xcb headers?)"
chmod 755 "$GOUT" "$GOUT/wine_state"
st() { J clients | jq -r '.[] | select(.class=="wine_state.exe") | "\(.fullscreen)/\(.fullscreenClient)"'; }
xdisplay() { hlog 4000 | grep -o 'DISPLAY: :[0-9]*' | tail -1 | grep -o ':[0-9]*$'; }
client_log() { SU sh -c "ls -t $ST/client.*.log" | head -1; }

rig_start; go 1; kw kk
wait_for 6 '[ -n "$(xdisplay)" ]' || { $R win env DISPLAY=:99 true >/dev/null 2>&1; wait_for 6 '[ -n "$(xdisplay)" ]'; }
D=$(xdisplay); [ -n "$D" ] || skip "XWayland never announced a display"
go 2; $R win env DISPLAY="$D" "$GOUT/wine_state" max 14 >/dev/null; LOG=$(client_log)
wait_for 5 '[ -n "$(st)" ]'
: > "$GOUT/max.samp"; end=$(( $(date +%s) + 8 ))
while [ "$(date +%s)" -lt $end ]; do st >> "$GOUT/max.samp"; sleep 0.05; done
changes=$(( $(uniq "$GOUT/max.samp" | wc -l) - 1 )); ns=$(grep -c / "$GOUT/max.samp")
check "A: the compositor answered and showed the client (>= 60 samples in 8 s)" "$(ge "$ns" 60)" "$ns samples"
check "A: at most one state change in 8 s" "$(le "$changes" 1)" "$changes changes: $(uniq -c "$GOUT/max.samp" | head -6 | awk '{printf "%sx%s ",$1,$2}')"
check "A: ends maximized (1/1)" "$(is "$(tail -1 "$GOUT/max.samp")" 1/1)" "$(tail -1 "$GOUT/max.samp")"
XID=$(SU head -1 "$LOG" | grep -oE '0x[0-9a-f]+')
$R win env DISPLAY="$D" sh -c "xprop -id $XID _NET_WM_STATE > $ST/xprop.txt 2>&1" >/dev/null; sleep 0.8
XP=$(SU cat "$ST/xprop.txt" 2>/dev/null | head -1)
check "A: X is told: _NET_WM_STATE has MAXIMIZED_VERT and _HORZ" "$(echo "$XP" | grep -q 'MAXIMIZED_VERT' && echo "$XP" | grep -q 'MAXIMIZED_HORZ' && echo 1)" "$XP"
late=$(SU cat "$LOG" | grep -oE 't= *[0-9]+s sent=[0-9]+' | awk '{ gsub(/t= */,""); split($0, a, "s sent="); if (a[1] >= 2) s += a[2] } END { print s + 0 }')
check "A: the client stops asking after its first second" "$(is "$late" 0)" "$late requests after 1 s"
rig_stop

rig_start; go 1; kw kk
wait_for 6 '[ -n "$(xdisplay)" ]' || { $R win env DISPLAY=:99 true >/dev/null 2>&1; wait_for 6 '[ -n "$(xdisplay)" ]'; }
D=$(xdisplay)
go 2; $R win env DISPLAY="$D" "$GOUT/wine_state" flap 30 >/dev/null
wait_for 5 '[ -n "$(st)" ]'; sleep 1.5
W=$(addr_of wine_state.exe); KK=$(addr_of kk); focus "$W"
XG=$(dbg xgeom | grep -o 'xstate:[^|]*' | head -1)
storms=$(echo "$XG" | grep -o 'storms=[0-9]*' | cut -d= -f2)
check "B: the flipping is caught (storms >= 1)" "$(ge "${storms:-0}" 1)" "$XG"
seq=; for k in 1 2 3 4; do ev "hl.dispatch(hl.dsp.window.fullscreen({ window = [[address:$W]], action = \"toggle\" }))"; sleep 0.25; seq="$seq $(st)"; done
check "B: user fullscreen toggles on it work during the block" "$(echo "$seq" | awk '{ ok = ($1 != $2 && $2 != $3 && $3 != $4) } END { print ok ? 1 : 0 }')" "states:$seq"
seq=; for k in 1 2 3 4; do ev "hl.dispatch(hl.dsp.window.fullscreen({ window = [[address:$KK]], mode = \"maximized\", action = \"toggle\" }))"; sleep 0.3; seq="$seq $(J clients | jq -r ".[] | select(.address==\"$KK\") | .fullscreen")"; done
check "B: user maximize toggles on another window work" "$(is "$seq" ' 1 0 1 0')" "fullscreen:$seq"
gate_end
