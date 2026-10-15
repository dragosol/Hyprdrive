-- hyprdrive fragment 36-settings-app -- the standalone settings window, and
-- the AC/battery watcher it needs on a desktop without the Omarchy shell.
--
-- MACHINE-OWNED above the raw-snippet marker; USER-OWNED below it. Everything
-- above BEGIN is rewritten wholesale when this fragment is regenerated;
-- everything between BEGIN and END is carried across verbatim.
--
-- 36, after 35-gestures (written by the settings) and before 40-panel.
--
-- MATCHED BY TITLE, NOT CLASS. Quickshell's windows are all class
-- org.quickshell (0.3 has no per-window app_id), so a class rule would also
-- catch a bar or any other Quickshell surface. The title is set before the
-- first commit, so the rule lands at map time. Floating and centred: it is a
-- dialog-sized window, and tiling it would squeeze the two-column page.
hl.window_rule({
    match = { title = [[^(Hyprdrive Settings)$]] },
    float = true,
    center = true,
})

-- Open the settings from a key: not bound by default (every chord is somebody's),
-- e.g. in hyprland.lua or below the marker. Guarded: with the plugin unloaded
-- or failing to load hl.plugin.hyprdrive is nil, and an unguarded line errors
-- and stops Hyprland registering the rest of your binds:
--   if hl.plugin.hyprdrive then
--     hl.bind("SUPER + COMMA", hl.plugin.hyprdrive.settings())
--     hl.bind("SUPER + SHIFT + COMMA", hl.plugin.hyprdrive.settings("pane dock"))
--   end

-- AC / BATTERY PROFILES with the settings closed. On Omarchy the bar panel
-- watches the charger (Panel.qml) for as long as the bar runs; here nothing is
-- resident, so a small watcher started with the session does it: it applies the
-- saved profile once the power state has held still (hdpanel profile-auto,
-- which does nothing in a forced mode or with no profile saved). It exits at
-- once on a machine with no battery.
if hyprdrive_omarchy and not hyprdrive_omarchy() then
    local watch = [==[@HYPRDRIVE_PREFIX@]==] .. "/lib/hyprdrive/hyprdrive-power-watch"
    local f = io.open(watch, "r")
    if f then
        f:close()
        hl.on("hyprland.start", function()
            hl.exec_cmd(watch)
        end)
    end
end
