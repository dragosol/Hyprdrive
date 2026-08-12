-- hyprdrive fragment 20-layout -- geometry of the overview itself.
--
-- MACHINE-OWNED above the raw-snippet marker; USER-OWNED below it. Everything
-- above BEGIN is rewritten wholesale when this fragment is regenerated;
-- everything between BEGIN and END is carried across verbatim.

if hyprdrive_loaded() then
    hl.config({
        plugin = {
            hyprdrive = {
                scale         = 0.82,
                layout        = "horizontal",   -- matches the quickshell overview left/right scroll
                workspace_gap = 40,
            },
        },
    })
end
