-- hyprdrive fragment 10-theme -- colours, frost and shadow.
--
-- MACHINE-OWNED above the raw-snippet marker; USER-OWNED below it. Everything
-- above BEGIN is rewritten wholesale when this fragment is regenerated;
-- everything between BEGIN and END is carried across verbatim. Lua's last
-- assignment wins and the raw block is last, so a line you write down there
-- overrides the generated value above -- that is the point of it.
--
-- 10, so the theme lands before the binds in 30 that act on it.

if hyprdrive_loaded() then
    hl.config({
        plugin = {
            hyprdrive = {
                -- The selection ring, strip outline, dock hover and search
                -- selection. NOT general:col.active_border -- on this rice
                -- matugen fills that from `outline_variant`, a dark brown that
                -- vanishes against the wallpaper. `primary` is the bright accent
                -- the pinned-window rule already uses.
                col_highlight = "rgba(ffb2b9ff)",

                wallpaper = 0,   -- one global wallpaper, as the rice has
                -- USER 2026-08-01: the overview wallpaper stays SHARP (rounded
                -- cards); the frost goes on the STRIP CELLS instead, in-plugin.
                -- This is the one documented exception to frost-everywhere.
                blur = false,

                shadow = {
                    enabled      = true,
                    range        = 20,          -- mirrors the tile RectangularShadow blur of 20
                    render_power = 3,
                    color        = 0x20000000,  -- the same 20000000 the tiles use
                },
            },
        },
    })
end
