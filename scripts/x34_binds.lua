
-- OVERVIEW_CPP_SPEC §13.9 X34. The dock hotkeys, read off the HOST's LIVE Dash
-- to Dock gsettings on 2026-08-03: app-hotkey-1..10 = <Super>1..<Super>0 (so
-- slot TEN is the 0 key), the <Shift> and <Ctrl> families beside them, and
-- `shortcut` = <Super>q at `shortcut-timeout` 2.0.
--
-- These COLLIDE with illogical-impulse's own SUPER+digit workspace focus and
-- with its SUPER+Q close, so each is unbound first. That is the host's layout
-- rather than a preference of mine: on the host GNOME binds nothing to
-- SUPER+digit, and its close is <Alt>F4 (`org.gnome.desktop.wm.keybindings
-- close`), which is the opposite of ii's arrangement and is restored below.
--
-- The whole set goes quiet with plugin:hyprdrive:dock:hot_keys = false --
-- the binds stay and dispatch into a no-op, exactly as the reference's
-- `hot-keys` switch removes the behaviour rather than the keys' meaning.
local numberkey = { 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 }
for slot = 1, 10 do
    -- The character AND the raw keycode, because ii binds both: a layout that
    -- puts a symbol on the number row would otherwise lose half the set.
    for _, key in ipairs({ tostring(slot % 10), "code:" .. numberkey[slot] }) do
        hl.unbind("SUPER + " .. key)
        hl.bind("SUPER + " .. key, hl.plugin.hyprdrive.hotkey(tostring(slot)),
            { description = "Dock: activate app " .. slot })
        hl.bind("SUPER + SHIFT + " .. key, hl.plugin.hyprdrive.hotkey("shift " .. slot),
            { description = "Dock: activate app " .. slot .. " (shift-click action)" })
        hl.bind("CTRL + SUPER + " .. key, hl.plugin.hyprdrive.hotkey("ctrl " .. slot),
            { description = "Dock: new window of app " .. slot })
    end
end

-- The NUMPAD digits keep ii's workspace focus. GNOME never bound them, so
-- taking them would be inventing a requirement instead of matching one.

hl.unbind("SUPER + Q")
hl.unbind("ALT + F4")
hl.bind("SUPER + Q", hl.plugin.hyprdrive.hotkey("overlay"),
    { description = "Dock: show the hotkey number overlay" })
hl.bind("ALT + F4", hl.dsp.window.close(), { description = "Window: Close (GNOME's own binding)" })
