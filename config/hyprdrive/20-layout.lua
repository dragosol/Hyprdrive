-- hyprdrive fragment 20-layout -- geometry of the overview itself.
--
-- MACHINE-OWNED above the raw-snippet marker; USER-OWNED below it. Everything
-- above BEGIN is rewritten wholesale when this fragment is regenerated;
-- everything between BEGIN and END is carried across verbatim.

if hyprdrive_loaded and hyprdrive_loaded() then
    hl.config({
        plugin = {
            hyprdrive = {
                scale         = 0.82,
                layout        = "horizontal",
                workspace_gap = 40,
                dock = {
                    -- Super+1..0 stay your workspace binds. The plugin still has
                    -- the hotkey dispatcher; Settings > Keybinds can hand them over.
                    hot_keys = false,
                },
            },
        },
    })
end
