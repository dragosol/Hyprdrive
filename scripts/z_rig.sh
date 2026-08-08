#!/bin/bash
# Z4-Z7 dock flight gates. usage: z_rig.sh <z4|z5|z6|z7>. Runs IN THE GUEST.
# z7/z6 print PASS/FAIL themselves; z4/z5 record films for zflight_gate.py.
set -u
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(cd /run/user/1000 && ls -t wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
export YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
OUT=/mnt/host/zrig; mkdir -p $OUT /mnt/host/x24d
cp ~/overview-cpp/scripts/x24_cell.py /mnt/host/ 2>/dev/null
W=$1

cfg(){ hyprctl eval "hl.config({plugin={scrolloverview={dock={$1}}}}) return 0" >/dev/null 2>&1; }
scale(){ hyprctl eval "hl.config({plugin={scrolloverview={anim_scale=$1}}}) return 0" >/dev/null 2>&1; }
ws(){ hyprctl dispatch "hl.dsp.focus({workspace = $1})" >/dev/null 2>&1; sleep 0.8; }
killothers(){ hyprctl clients -j | python3 -c "import json,sys
for c in json.load(sys.stdin):
    if c.get('class') not in ('zfix','') and c.get('pid',0)>0: print(c['pid'])" | xargs -r kill -9 2>/dev/null; }
# Nautilus gets D-Bus-activated back to life BETWEEN a single startup sweep and
# the click (measured: two rig runs, two different corpses in the dock), so the
# sweep runs immediately before EVERY click.
click(){ killothers; sleep 0.6; bash ~/overview-cpp/scripts/x24_dock_click.sh zfix >/dev/null 2>&1; }
# x24_cell.py still models a MINIMIZED window as icon+preview-slot; X46 deleted
# the preview slot, so its x lands 46px left of the real single cell. With
# every other dock item off and one class, the cell sits at screen centre by
# symmetry -- click there. Rig-local; the shared locator stays untouched.
clickcenter(){ killothers; sleep 0.6
  ydotool mousemove -a -x 640 -y 778 2>/dev/null; sleep 0.5
  ydotool click 0x40; for d in 2 -2 3 -1 0; do ydotool mousemove -a -x $((640+d)) -y $((778-d)) 2>/dev/null; sleep 0.025; done; ydotool click 0x80; }
# no tail sleep in clickcenter: z6 samples the active workspace 150ms after the
# press, and a tail put that sample past the OLD build's landing-time switch --
# the control passed a gate it must fail. Callers own their waits.
spawn(){ setsid -f kitty --class zfix --override background=#00ff00 sh -c 'sleep 3600' </dev/null >/dev/null 2>&1; sleep 1.5
  hyprctl eval "$(cat <<'LUA'
for _, w in ipairs(hl.get_windows()) do
    if w.class == "zfix" then
        hl.dispatch(hl.dsp.focus({window = w}))
        hl.dispatch(hl.dsp.window.resize({x = 800, y = 500, relative = false}))
        hl.dispatch(hl.dsp.window.move({x = 600, y = 300, relative = false}))
    end
end
return 1
LUA
)" >/dev/null 2>&1; sleep 0.8; }
J(){ python3 -c "import json,sys;$1" ; }
activews(){ hyprctl monitors -j | J "print(json.load(sys.stdin)[0]['activeWorkspace']['id'])"; }
fixws(){ hyprctl clients -j | J "print(next((c['workspace']['name'] for c in json.load(sys.stdin) if c['class']=='zfix'),'GONE'))"; }
focusedc(){ hyprctl activewindow -j | J "print(json.load(sys.stdin).get('class','NONE'))"; }

systemctl --user stop hyprwall.timer 2>/dev/null
pkill -x kitty 2>/dev/null
# The cell locator predicts from RUNNING classes, so every OTHER mapped window
# shifts every icon centre and the click lands on the wrong app -- measured:
# z7's first run focused Nautilus. A gate needs a dock containing only the
# fixture; kill everything else that owns a window.
hyprctl clients -j | python3 -c "import json,sys
for c in json.load(sys.stdin):
    if c.get('class') not in ('zfix','') and c.get('pid',0)>0: print(c['pid'])" | xargs -r kill 2>/dev/null
sleep 1.5
# Favourites are pinned icons the cell locator cannot model (it predicts from
# running classes); with them shown the click lands on a favourite -- measured,
# probe.png. The gate runs on a running-apps-only dock and restores after.
cfg "autohide=false"; cfg "show_favorites=false"; cfg "show_trash=false"; cfg "show_mounts=false"; cfg "show_apps_button=false"; cfg "flight_log=true"; sleep 0.8

case "$W" in
  z7)
    ws 2; spawn; ws 1
    click; sleep 2.0
    A=$(activews); F=$(focusedc); X=$(fixws)
    [ "$A" = 2 ] && [ "$F" = zfix ] && [ "$X" = 2 ] && echo "z7 PASS (ws=$A focus=$F fixws=$X)" \
                                                   || echo "z7 FAIL (ws=$A focus=$F fixws=$X)"
    ;;
  z6)
    ws 2; spawn
    click; sleep 2.0                                  # minimize, on its own desktop
    # Gate the INTERMEDIATE state: if this click missed, the restore click below
    # exercises Z7's goto-branch instead and the final asserts pass for the
    # wrong reason -- the two behaviours are indistinguishable from the end
    # state alone.
    [ "$(fixws)" = special:minimized ] || { echo "z6 FAIL (minimize step missed, fixws=$(fixws))"; exit 1; }
    ws 1; sleep 0.5
    clickcenter                                       # restore: must switch back + land
    sleep 0.15; MID=$(activews)                       # DURING the flight: the switch
                                                      # happens at CLICK time now; the
                                                      # old code switched at LANDING,
                                                      # reaching the same END state
    sleep 3.0
    A=$(activews); F=$(focusedc); X=$(fixws)
    [ "$A" = 2 ] && [ "$F" = zfix ] && [ "$X" = 2 ] && [ "$MID" = 2 ] && echo "z6 PASS (ws=$A mid=$MID focus=$F fixws=$X)" \
                                                                     || echo "z6 FAIL (ws=$A mid=$MID focus=$F fixws=$X)"
    ;;
  z4)
    ws 1; spawn
    scale 10
    click; sleep 6                                     # minimize (4s scaled) fully lands
    [ "$(fixws)" = special:minimized ] || { echo "z4 RIG FAULT: minimize missed"; exit 1; }
    rm -f $OUT/z4.mp4
    wf-recorder -f $OUT/z4.mp4 -c libvpx-vp9 -r 30 >$OUT/z4-wfr.log 2>&1 & WFR=$!
    sleep 2.5
    clickcenter; sleep 7                               # restore + landing + slack (stashed = single cell, see clickcenter)
    [ "$(fixws)" = 1 ] || { echo "z4 RIG FAULT: restore missed (fixws=$(fixws))"; exit 1; }
    kill -INT $WFR 2>/dev/null; wait $WFR 2>/dev/null
    scale 1
    rm -f $OUT/z4-*.png; ffmpeg -loglevel error -i $OUT/z4.mp4 $OUT/z4-%03d.png
    echo "z4 filmed: $(ls $OUT/z4-*.png | wc -l) frames"
    ;;
  z4t)
    # The user's "slight bug on first maximize" (video 2026-08-07 11:02): a
    # TILED window's restore grew out of the stash workspace's own retile box
    # instead of flying to its tile -- flightAnchorBox read the stashed
    # geometry. The flight now aims at Minimize::originalBox. Same hole gate
    # as z4; the fixture is forced tiled first.
    ws 1; spawn
    F=$(hyprctl clients -j | python3 -c "import json,sys; print([c['"'"'floating'"'"'] for c in json.load(sys.stdin) if c['"'"'class'"'"']=='"'"'zfix'"'"'][0])")
    [ "$F" = "True" ] && { hyprctl dispatch "hl.dsp.window.float()" >/dev/null 2>&1; sleep 0.6; }
    click; sleep 1.5
    [ "$(fixws)" = special:minimized ] || { echo "z4t RIG FAULT: minimize missed"; exit 1; }
    rm -f $OUT/z4t.mp4
    wf-recorder -f $OUT/z4t.mp4 -c libvpx-vp9 -r 30 >$OUT/z4t-wfr.log 2>&1 & WFR=$!
    sleep 2.5
    clickcenter; sleep 3
    kill -INT $WFR 2>/dev/null; wait $WFR 2>/dev/null
    [ "$(fixws)" = 1 ] || { echo "z4t RIG FAULT: restore missed (fixws=$(fixws))"; exit 1; }
    echo "z4t filmed"
    ;;
  z4c)
    # Z18 regression gate: REPEATED cycles with a zombie overview registered.
    # An overview object persists after close (reopen design); treating "object
    # exists" as "overview open" sent desktop restores down the proxy path,
    # whose landing never restored geometry -- each cycle shrank the window
    # x0.82 and the layout target drifted (user screenshots, 2026-08-08).
    ws 1; spawn
    hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[on]]))" >/dev/null 2>&1; sleep 1.5
    hyprctl eval "return hl.dispatch(hl.plugin.scrolloverview.overview([[off]]))" >/dev/null 2>&1; sleep 1.5
    BOX0=$(hyprctl clients -j | python3 -c "import json,sys; c=[x for x in json.load(sys.stdin) if x['class']=='zfix'][0]; print(c['at'],c['size'])")
    FAIL=0
    for i in 1 2 3; do
      click; sleep 1.2
      [ "$(fixws)" = special:minimized ] || { echo "z4c RIG FAULT: minimize $i missed"; exit 1; }
      clickcenter; sleep 1.5
      B=$(hyprctl clients -j | python3 -c "import json,sys; c=[x for x in json.load(sys.stdin) if x['class']=='zfix'][0]; print(c['at'],c['size'])")
      [ "$B" = "$BOX0" ] || { echo "z4c FAIL: cycle $i geometry $B != $BOX0"; FAIL=1; }
    done
    [ "$FAIL" = 0 ] && echo "z4c PASS: 3 cycles, geometry invariant $BOX0"
    ;;
  z5)
    ws 1; spawn
    # NO anim_scale: flights run on the wall clock (measured -- a scaled run's
    # clicks all landed after each 400ms flight had finished, and the gate was
    # testing nothing). Real spam: park the mouse on the cell once, then three
    # fast held presses ~250ms apart, all inside one flight's lifetime.
    killothers; sleep 0.6
    rm -f $OUT/z5.mp4
    wf-recorder -f $OUT/z5.mp4 -c libvpx-vp9 -r 30 >$OUT/z5-wfr.log 2>&1 & WFR=$!
    sleep 2.5
    ydotool mousemove -a -x 640 -y 778 2>/dev/null; sleep 0.4
    for i in 1 2 3; do
      ydotool click 0x40
      for d in 2 -2 1; do ydotool mousemove -a -x $((640+d)) -y $((778-d)) 2>/dev/null; sleep 0.03; done
      ydotool click 0x80
      sleep 0.15
    done
    sleep 4
    kill -INT $WFR 2>/dev/null; wait $WFR 2>/dev/null
    [ "$(fixws)" = special:minimized ] || { echo "z5 RIG FAULT: odd click count should end minimized (fixws=$(fixws))"; exit 1; }
    rm -f $OUT/z5-*.png; ffmpeg -loglevel error -i $OUT/z5.mp4 $OUT/z5-%03d.png
    echo "z5 filmed: $(ls $OUT/z5-*.png | wc -l) frames"
    ;;
esac
cfg "autohide=true"; cfg "show_favorites=true"; cfg "show_trash=true"; cfg "show_apps_button=true"; cfg "flight_log=false"
