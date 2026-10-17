-- hyprdrive fragment 10-theme -- appearance is Hyprland's, so this file pins
-- nothing.
--
-- The plugin reads live compositor values (see Config.hpp):
--   accent     general:col.active_border          -> highlightColor()
--   cards      decoration:rounding                -> themeRounding()
--   search     same plate as the dock, rounding   -> themePlate() / drawSearch()
--   results    from decoration:rounding (0 stays
--   strip      squared). Dock rounding stays 24.
--   blur       decoration:blur:*                  -> dock/search frost; off when
--              decoration:blur:enabled is false
--   canvas     plugin:hyprdrive:blur              -> dimmed, blurred wallpaper behind
--              the cards (its own constants), not window blur
--   shadows    decoration:shadow:*                -> plugin shadow at -1
--   dock pill  theme:background / palette_file /   -> dockBackgroundColor()
--              misc:background_color, at decoration:inactive_opacity
--              (Omarchy: its colors.toml, times default-opacity 0.85)
--   type       plugin font / misc:font_family /    -> themeFontFamily()
--              fontconfig monospace (Omarchy: its font)
--   dock dots  the same accent                    -> dockIndicatorColor()
--   dock radius dock:corner_radius (24)           -> dockCornerRadius()
--               the pill and its highlights keep the original Dash-to-Dock
--               rounding; they do not follow decoration:rounding.
--
-- Those keys follow your Hyprland config (on Omarchy, `omarchy theme set`
-- writes them and reloads). Do not set col_highlight or dock colours here: a
-- pin would freeze the last value and stop following the theme.
-- To pin deliberately, put the key in the raw-snippet block below.

if hyprdrive_loaded and hyprdrive_loaded() then
    hl.config({
        plugin = {
            hyprdrive = {
                wallpaper = 0,
            },
        },
    })
end
