#!/usr/bin/env bash
# dock_click -- a dock ICON click minimizes/restores the app's windows on the active desktop, without moving the pointer.
# Protects (designed behaviours, Focus and attention):
#   "Dock: clicking an app ICON minimizes/restores that app's windows on the
#    active workspace (no cursor move); clicking a PREVIEW or Ctrl+click focuses [11-09]"
#   "Switching to a window from the dock previews or overview puts the cursor on
#    it, centred [10-29, 11-09]"
#   and the minimize/restore flight ends with the window at its box.
# `hyprdrive:debug activate <class>` is exactly a left click on the icon (the
# rig's dock is out of a real pointer's reach). Preview clicks and Ctrl+click
# are NOT covered: the hook takes no modifiers (Ctrl held on the rig's keyboard
# is ignored by it) and previews have no hook (see COVERAGE.md).
# Asserts, app windows on desktops 1 and 2, `other` focused on 1, pointer at 500,500:
#   1. first click: app's window on 1 comes forward (focused), nothing minimized
#   2. second click (app focused): its window on 1 is minimized; the one on 2 is not
#   3. third click: it is restored to the very box it had; the one on 2 untouched
#   4. the pointer never moved
# Control (--control): the "click" only focuses the app's window, as a preview
# click does -- 2 fails (nothing is minimized) and 4 fails (Hyprland's focus
# warps the pointer). Recorded 2026-11-11
# on 3ad1da3: control FAILS as it must.
source "$(dirname "$0")/lib.sh"
gate_begin dck
rig_start
go 2; kw app 900 600; go 1; kw app 700 450; kw other 600 400; sleep 0.5
$R ptr move 500 500 >/dev/null; sleep 0.3
on1() { J clients | jq -r '.[] | select(.class == "app" and .workspace.id != 2) | "\(.workspace.name) \(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"'; }
on2() { J clients | jq -r '.[] | select(.class == "app" and .workspace.id == 2) | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"'; }
click() {
    # control: an icon that only FOCUSES the app's window (what a preview click does)
    if [ "$CONTROL" = 1 ]; then focus "$(J clients | jq -r '.[] | select(.class == "app" and .workspace.id == 1) | .address')"
    else dbg activate app >/dev/null; fi
    sleep 1.1   # the minimize/restore flight is 400 ms (dock:minimize_ms) plus the layout's own
}
C0=$(hq cursorpos); BOX=$(on1); B2=$(on2)
click
check "1: first click brings the app forward" "$(is "$(J activewindow | jq -r .class)" app)" "focus $(J activewindow | jq -r .class)"
check "1: nothing minimized" "$(is "$(on1 | grep -c special)" 0)" "$(on1)"
click; M=$(on1)
check "2: second click minimizes its window on this desktop" "$(echo "$M" | grep -q '^special:minimized' && echo 1)" "$M"
check "2: not the one on desktop 2" "$(is "$(on2)" "$B2")" "$(on2) was $B2"
click
check "3: third click restores it to its box" "$(is "$(on1)" "$BOX")" "$(on1), was $BOX"
check "3: desktop 2's untouched" "$(is "$(on2)" "$B2")" "$(on2)"
check "4: the pointer never moved" "$(is "$(hq cursorpos)" "$C0")" "$(hq cursorpos), was $C0"
gate_end
