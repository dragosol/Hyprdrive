#!/usr/bin/env bash
# OVERVIEW_CPP_SPEC 13.9 X34: dock hotkeys and the number overlay. Runs IN THE GUEST.
#
# Most of X34's claims are STATE -- which windows are minimized, how many
# clients of a class exist, whether an app got launched -- so they are asserted
# directly. Only the overlay itself is pixels, and those go to the host
# (share/x34_gate.py); the guest has no numpy.
#
# The rules earlier rigs paid for are still in force:
#   * ydotool's absolute space is HALF this guest's output.
#   * a phase that cannot fail is not a phase.
#   * a capture identical to its control is a FAIL, not a pass: a throttled
#     output hands back the same frame forever and it reads as "nothing moved".
set -u
source "$(dirname "$0")/lib/rig.sh"
rig_env || exit 1
OUT=/mnt/host/x34shots
STORE=$HOME/.local/state/scrolloverview/favorites
mkdir -p $OUT

key()   { hyprctl eval "return hl.config({ plugin = { scrolloverview = { dock = { $1 = $2 } } } })" >/dev/null; }
warp()  { ydotool mousemove -a -x $(( $1 / 2 )) -y $(( $2 / 2 )) 2>/dev/null; sleep 0.25; }
dsp()   { hyprctl eval "return hl.dispatch($1)" >/dev/null; }
hot()   { dsp "hl.plugin.scrolloverview.hotkey([[$1]])"; }
nclass(){ hyprctl clients -j | python3 -c "import json,sys; print(sum(1 for c in json.load(sys.stdin) if c['class']=='$1'))"; }
verdict(){ if [ "$2" = "$3" ]; then echo "PASS $1: $2"; else echo "FAIL $1: got [$2] want [$3]"; fi; }

# Minimized windows are off the compositor's workspace list, so "visible" is
# what hyprctl still reports on a real workspace. This is the same ruler X24's
# minimize rig used, not a new one.
nvis()  { hyprctl clients -j | python3 -c "
import json,sys
print(sum(1 for c in json.load(sys.stdin) if c['class']=='$1' and c['workspace']['id'] > 0))"; }

read -r MON W H <<< "$(hyprctl monitors -j | python3 -c "
import json,sys
m = json.load(sys.stdin)[0]
print(m['name'], m['width'], m['height'])")"
shot() { grim -o "$MON" $OUT/$1.png; }
park() { warp $((W / 2)) $((H / 3)); sleep 0.4; }

case "${1:?usage: x34_rig.sh <phase>}" in

seed3)
    mkdir -p "$(dirname $STORE)"
    printf 'kitty\norg.gnome.Nautilus\norg.gnome.Calculator\n' > $STORE
    echo "SEEDED $(tr '\n' ' ' < $STORE)"
    ;;

# Eleven favourites: the tenth slot is the `0` key, and an ELEVENTH proves the
# overlay stops at ten instead of numbering everything it can see.
seed11)
    mkdir -p "$(dirname $STORE)"
    # Every id here is one this guest actually ships: a favourite whose desktop
    # entry is missing is dropped from the layout, and the first cut of this
    # phase silently measured seven items while claiming eleven.
    printf 'kitty\norg.gnome.Nautilus\norg.gnome.Calculator\norg.gnome.Characters\norg.gnome.clocks\norg.gnome.Contacts\norg.gnome.Weather\norg.gnome.Settings\norg.kde.plasma-systemmonitor\norg.kde.dolphin\norg.pulseaudio.pavucontrol\n' > $STORE
    echo "SEEDED11 $(wc -l < $STORE)"
    ;;

fixture)
    hyprwall_pause 40min

    dsp "hl.plugin.scrolloverview.overview([[off]])" 2>/dev/null
    sleep 0.5
    pkill -x nautilus 2>/dev/null; pkill -x gnome-calculator 2>/dev/null
    pkill -f kitty 2>/dev/null; sleep 1.0
    dsp "hl.dsp.focus({ workspace = 1 })"; sleep 0.6
    for i in 1 2 3; do
        setsid -f kitty --override background=#20${i}0${i}0 -o confirm_os_window_close=0 \
            sh -c 'while :; do sleep 1; done' </dev/null >/dev/null 2>&1
        sleep 1.2
    done
    sleep 1.5

    key enabled true
    key autohide false
    key notification_counter false
    key dance_urgent false
    key running_indicator false
    key show_favorites true
    key show_apps_button false
    key isolate_workspaces false
    key hot_keys true
    key hotkeys_overlay true
    key hotkeys_show_dock true
    key shortcut_timeout 2.0
    park; sleep 1.0
    echo "X34_FIXTURE mon=$MON ${W}x${H} kitty=$(nclass kitty) vis=$(nvis kitty)"
    ;;

pill)
    key enabled false; sleep 1.0
    shot "$2_e0"; sleep 1.0; shot "$2_e1"
    key enabled true;  sleep 1.2
    shot "$2_on"
    echo PILL_OK
    ;;

# P1. Slot 1 is kitty and kitty is running: the reference's plain hotkey runs the
# SAME action a plain click runs, so one window goes down and the rest stay.
slot1)
    B=$(nvis kitty)
    hot 1; sleep 1.2
    A=$(nvis kitty)
    echo "SLOT1 visible $B -> $A"
    verdict slot1 "$A" "$((B - 1))"
    ;;

# P2. Shift takes the whole app down, exactly as a shift-click does.
slot1shift)
    B=$(nvis kitty)
    hot "shift 1"; sleep 1.4
    A=$(nvis kitty)
    echo "SLOT1SHIFT visible $B -> $A (total kitty $(nclass kitty))"
    verdict slot1shift "$A" "0"
    ;;

# P3. Slot 2 is Nautilus: PINNED and NOT running. It has to launch, and it has
# to be slot TWO -- an off-by-one would hit kitty or Calculator and this is the
# only phase that can tell.
slot2)
    B=$(nclass org.gnome.Nautilus)
    hot 2; sleep 4.0
    A=$(nclass org.gnome.Nautilus)
    echo "SLOT2 nautilus $B -> $A"
    verdict slot2 "$A" "1"
    ;;

# P4. Ctrl is a NEW window of a running app, not a focus change.
ctrl1)
    hot 1; sleep 1.0          # bring kitty back up first, so this is not a restore
    B=$(nclass kitty)
    hot "ctrl 1"; sleep 3.5
    A=$(nclass kitty)
    echo "CTRL1 kitty $B -> $A"
    verdict ctrl1 "$A" "$((B + 1))"
    ;;

# P5. The overlay, with controls on BOTH sides of the measured frame. If _c0 and
# _c1 come back identical to _up the output is stalled and the gate says so.
overlay)
    park
    shot "$2_c0"; sleep 0.6
    hot overlay; sleep 0.5
    shot "$2_up"
    sleep 2.6                 # shortcut_timeout 2.0 plus slack
    shot "$2_c1"
    echo OVERLAY_SHOT
    ;;

# P6. A slot with no item still shows the overlay and activates nothing: the
# reference's callback shows the numbers whether or not _activateApp found an app.
empty)
    park
    shot "$2_c0"; sleep 0.6
    B=$(nclass kitty)$(nclass org.gnome.Nautilus)$(nclass org.gnome.Calculator)
    hot 9; sleep 0.5
    shot "$2_up"
    sleep 2.6
    shot "$2_c1"
    A=$(nclass kitty)$(nclass org.gnome.Nautilus)$(nclass org.gnome.Calculator)
    echo "EMPTY counts $B -> $A"
    verdict empty_noactivate "$A" "$B"
    ;;

# P7. Ten circles for eleven items.
ten)
    park
    shot "$2_c0"; sleep 0.6
    hot overlay; sleep 0.5
    shot "$2_up"
    sleep 2.6
    shot "$2_c1"
    echo TEN_SHOT
    ;;

# P8. hotkeys-show-dock: autohide on, pointer parked away, dock down. The
# overlay shortcut alone has to bring it back.
showdock)
    key autohide true; sleep 1.6
    park; sleep 1.6
    shot "$2_hidden"
    hot overlay; sleep 0.8
    shot "$2_shown"
    sleep 2.8
    shot "$2_again"
    key autohide false; sleep 1.2
    echo SHOWDOCK_SHOT
    ;;

# P9. The switch. hot_keys false and the whole set goes quiet -- no overlay, no
# activation -- while the binds themselves stay exactly where they were.
off)
    key hot_keys false; sleep 0.8
    park
    shot "$2_c0"; sleep 0.6
    B=$(nvis kitty)
    hot overlay; sleep 0.5
    shot "$2_up"
    hot 1; sleep 1.2
    A=$(nvis kitty)
    sleep 0.6
    shot "$2_c1"
    # Back on, and one more frame. "Nothing was drawn" is only worth anything if
    # this same output can still be shown drawing something.
    key hot_keys true; sleep 0.8
    hot overlay; sleep 0.5
    shot "$2_live"
    sleep 2.6
    echo "OFF visible $B -> $A"
    verdict off_noactivate "$A" "$B"
    ;;

*) echo "unknown phase $1"; exit 2 ;;
esac
