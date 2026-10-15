-- hyprdrive fragment 50-desktop-scroll -- Super+scroll through the desktops.
--
-- MACHINE-OWNED above the raw-snippet marker; USER-OWNED below it. Everything
-- above BEGIN is rewritten wholesale when this fragment is regenerated;
-- everything between BEGIN and END is carried across verbatim.
--
-- <mods>+wheel down is the next desktop, <mods>+wheel up the previous one, on
-- the focused monitor, BY NUMBER: empty desktops are visited too (Hyprland's
-- "r+1"/"r-1"), from 1 up to 10 or the highest desktop there, without wrapping,
-- one desktop per wheel notch (hl.plugin.hyprdrive.desktop, DesktopSwitch.hpp).
-- With the overview open it moves the overview's desktop card instead.
--
--   plugin:hyprdrive:binds:scroll_desktops       true  (false: no binds here)
--   plugin:hyprdrive:binds:scroll_desktops_mods  "SUPER"
--
-- 50, AFTER 40-panel.lua: the settings write those two keys there, and this
-- reads them as they stand once everything before it has run (a key set in
-- hyprland.lua before require("hyprdrive") counts too).
--
-- A second bind on a chord does not replace the first (both would fire), so
-- whatever already had <mods>+mouse_down / mouse_up -- Omarchy's "Scroll active
-- workspace" (e+1 / e-1, which skips empty desktops) -- is unbound first, the
-- same unbind-then-bind 40-panel.lua does for Super+L. Inside
-- hyprdrive_loaded() only: with the plugin missing, the config's own binds stay.
-- Turning the key off removes these lines' effect on the next parse, and the
-- config's own binds come back with it.

if hyprdrive_loaded and hyprdrive_loaded() and hl.plugin.hyprdrive and hl.plugin.hyprdrive.desktop then
    -- hl.get_config answers a plugin key once the plugin has registered it.
    -- pcall + type checks: a Hyprland without get_config, or Omarchy's
    -- keybinding scanner (whose stub `hl` answers everything with a table),
    -- falls back to the defaults.
    local function option(key, fallback)
        local ok, value = pcall(function()
            return hl.get_config("plugin:hyprdrive:" .. key)
        end)
        if not ok or value == nil or type(value) == "table" then
            return fallback
        end
        return value
    end

    local on = option("binds:scroll_desktops", true)
    if on == true or on == 1 then
        local mods = option("binds:scroll_desktops_mods", "SUPER")
        if type(mods) ~= "string" or mods == "" or mods == "[[EMPTY]]" then
            mods = "SUPER"
        end
        -- Not a loop over a table: see 00-plugin.lua on pairs/ipairs and the
        -- keybinding scanner.
        hl.unbind(mods .. " + mouse_down")
        hl.unbind(mods .. " + mouse_up")
        hl.bind(mods .. " + mouse_down", hl.plugin.hyprdrive.desktop("next"), { description = "Next desktop (empty ones too)" })
        hl.bind(mods .. " + mouse_up", hl.plugin.hyprdrive.desktop("prev"), { description = "Previous desktop (empty ones too)" })
    end
end
