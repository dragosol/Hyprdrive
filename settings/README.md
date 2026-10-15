# Hyprdrive Settings (standalone)

The settings for plain Hyprland, where there is no Omarchy shell to host the
bar panel. Same rows, same back ends, its own window:

- `shell.qml` -- the window (Quickshell `FloatingWindow`, title
  "Hyprdrive Settings"), single-instance IPC (`hyprdrive-settings` target) and
  the deep links.
- `SettingsPage.qml` -- the page: `omarchy-plugin/HyprdrivePanel.qml` without
  `qs.Commons` / `qs.Ui`, kept a near line-for-line copy (differences are marked
  NATIVE). Rows come from `Schema.js`; values go through `bin/hdpanel` and the
  Icons section through `bin/hdicons`, exactly as in the panel.
- `Schema.js`, `Model.js`, `hyprdrive-icon.png` -- symlinks to the panel's own
  files. Quickshell refuses imports from outside the app's directory, so these
  are links rather than `../` imports; `make install` copies them.
- `hyprdrive-settings` -- the launcher: `--pane ID`, `--icons APPID`,
  `--toggle`, `--close`. On Omarchy it hands over to the bar panel.
- `hyprdrive-power-watch` -- applies the AC/battery profile when the charger
  changes (the bar panel does this on Omarchy); started by
  `config/hyprdrive/36-settings-app.lua`.

Colours are hyprdrive's own derived palette (`hyprctl hyprdrive-theme -j`), so
the window matches the dock and overview and follows a theme reload.

Open it from a key with the `settings` dispatcher, e.g. in hyprland.lua:

```lua
-- Guarded: if the plugin is unloaded or fails to load, hl.plugin.hyprdrive is
-- nil, and an unguarded line would stop Hyprland registering ANY of your binds.
if hl.plugin.hyprdrive then
  hl.bind("SUPER + COMMA", hl.plugin.hyprdrive.settings())
  hl.bind("SUPER + SHIFT + COMMA", hl.plugin.hyprdrive.settings("pane dock"))
end
```

`make install` installs it when Integration says this is not Omarchy
(`scripts/hyprdrive-integration`). Run from a checkout:
`settings/hyprdrive-settings` (uses `omarchy-plugin/bin/hdpanel` beside it).
