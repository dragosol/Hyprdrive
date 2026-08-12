-- hyprdrive fragment 30-keybinds -- the overview submap and the dock hotkeys.
--
-- MACHINE-OWNED above the raw-snippet marker; USER-OWNED below it. Everything
-- above BEGIN is rewritten wholesale when this fragment is regenerated;
-- everything between BEGIN and END is carried across verbatim.
--
-- 30, so it loads after the theme values in 10/20 and after ii's own keybinds:
-- it UNBINDS several of theirs, and an unbind that runs before the bind does
-- nothing.

-- Tapping SUPER alone toggles the overview. There is deliberately NO bind here:
-- the plugin detects the tap itself (main.cpp registerTapSuper), because on
-- 0.56.1 every bind form on SUPER_L fires the same whether SUPER was tapped or
-- held as a modifier, so a bind fires on every SUPER+<key> shortcut too.
-- Disable with: plugin:hyprdrive:tap_super = false

-- P0 fix (2026-08-01): while the overview is open the plugin enters this submap
-- (it does so only because these binds exist). Inside it the global
-- `SUPER + mouse:272 -> window.drag` bind cannot match, so a click with SUPER
-- still held reaches the overview instead of being eaten by the drag bind --
-- that was the "clicking a window does not focus it" bug. Motion still turns
-- into real tile drags via the plugin's pending machinery; only clean clicks
-- dispatch these binds.
hl.define_submap("hyprdrive", function()
    hl.bind("mouse:272",         hl.plugin.hyprdrive.window([[click]]), { mouse = true, description = "Overview: select" })
    hl.bind("SUPER + mouse:272", hl.plugin.hyprdrive.window([[click]]), { mouse = true, description = "Overview: select (SUPER held)" })
end)

-- OVERVIEW_CPP_SPEC 13.9 X34. The dock hotkeys, read off the HOST's LIVE Dash
-- to Dock gsettings on 2026-08-03: app-hotkey-1..10 = <Super>1..<Super>0 (so
-- slot TEN is the 0 key), the <Shift> and <Ctrl> families beside them, and
-- `shortcut` = <Super>q at `shortcut-timeout` 2.0.
--
-- These COLLIDE with illogical-impulse's own SUPER+digit workspace focus and
-- with its SUPER+Q close, so each is unbound first. That is the host's layout
-- rather than a preference: on the host GNOME binds nothing to SUPER+digit, and
-- its close is <Alt>F4 (`org.gnome.desktop.wm.keybindings close`), which is the
-- opposite of ii's arrangement and is restored below.
--
-- The whole set goes quiet with plugin:hyprdrive:dock:hot_keys = false -- the
-- binds stay and dispatch into a no-op, exactly as the reference's `hot-keys`
-- switch removes the behaviour rather than the keys' meaning.
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
