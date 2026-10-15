## Hyprdrive ↔ Omarchy coupling audit

**Scope.** I read the source on the XPS at `~/Projects/hyprdrive-omarchy` @ 020c4cd. Nothing there was changed. The fedora branch `hyprland-native` (`~/Projects/hyprdrive-native`, HEAD 89c28e8) is that same tree with only `scripts/headless/*` added, so every line number below applies to both. This was static reading only: nothing was built or run, so the effects described under "Without Omarchy" are inferred from the code, not observed.

**Testing caveat on fedora.** fedora is not an Omarchy-free machine.
- `/usr/share/omarchy/` exists. It is root-owned, comes from no package, and holds `default/omarchy/omarchy-menu.jsonc` and `shell/`.
- `hyprtest` already has `~/.config/omarchy/` (plugins, themes, extensions) and `~/.local/state/omarchy/`.

Because `/usr/share/omarchy` cannot be removed without root, a "no Omarchy" test there will still load the Omarchy menu. Fix: add an override (item P0-1 below) and move hyprtest's own Omarchy directories aside during vanilla tests.

### A. Couplings that break or misbehave without Omarchy

| # | file:line | What it does | Without Omarchy | Native replacement |
|---|---|---|---|---|
| 1 | `config/hyprdrive/25-rules.lua:72,80` | `o.window(...)` uses Omarchy's Lua helper global `o` (defined in `/usr/share/omarchy/default/hypr/helpers.lua:3,142`). Line 80 also uses Omarchy's `default-opacity` tag and its 0.985/0.85 values. | `o` is nil, so this is a Lua runtime error. The loader `dofile`s in order, so `30-keybinds.lua` (overview submap and default 3-finger gestures) never runs. The error also travels up through `require("hypr.hyprdrive")` in hyprland.lua; how Hyprland 0.56 handles that is unverified, and it is the first thing to test headless. | Use plain `hl.window_rule` for the Sushi float/center rule. Drop the default-opacity line, or put it under `if o then`. |
| 2 | `config/hyprdrive/00-plugin.lua:39` | Falls back to `~/Projects/hyprdrive-omarchy/hyprdrive.so`. | Harmless, but it is a dev path. | Use `HYPRDRIVE_SO`, `$PREFIX/lib/hyprdrive`, then the hyprpm path. |
| 3 | `scripts/install-fragments.sh:56-114` (`make install`) | Copies the panel into `~/.config/omarchy/plugins/dragos.hyprdrive` (`mkdir -p` makes the path even with no Omarchy) and runs `omarchy-plugin-reload-pause` (that part is guarded by `command -v`). | Creates a stray `~/.config/omarchy` tree. Line 36 requires `~/.config/hypr/hyprland.lua`; with a hyprlang `hyprland.conf` nothing loads, it only prints a hint. | Only install the panel when Omarchy is detected. A native install puts fragments and the loader in place and says clearly that the Lua config is required. |
| 4 | `OmarchySearch.cpp:1319-1321, 1898-1900` | The search's menu column parses `/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc` plus the user extension. | Nothing is parsed (the per-frame mtime stat is cheap). | See 5. |
| 5 | `OmarchySearch.cpp:1400-1420` | With no menu file, the browse mode at root falls back to `ROOT_DEFAULTS`: `omarchy-system-lock`, `omarchy-capture-screenshot`, `omarchy-toggle-nightlight`, `omarchy-theme-switcher`, `omarchy-system-shutdown`. | Five rows are shown that do nothing: `bash -c` gives "command not found", silently (`activate()` at `:2010`). | A "System" source with native commands: `loginctl lock-session`, `systemctl poweroff/reboot/suspend`, and grim+slurp only if present. Optionally a user `~/.config/hyprdrive/menu.jsonc` in the same schema, so the parser can be reused. |
| 6 | `OverviewInternal.hpp:778`, `OverviewRender.cpp:452`, `OmarchySearch.cpp:1303,1352,1358` | Column 0 is titled "Omarchy Menu". | Wrong label. | Name it "System", or "Omarchy Menu" only when detected. |
| 7 | `OmarchySearch.cpp:389-409` | Every agent's command runs through `omarchy-launch-tui --app-id=org.omarchy.agent …` or `omarchy-agent`. | An exact `/claude foo` query (`:660`, which skips the readiness check) gives a row that does nothing when activated. | Spawn `$TERMINAL`, `xdg-terminal-exec`, or a configurable `plugin:hyprdrive:search:terminal` with an `-e agent args` template. |
| 8 | `OmarchySearch.cpp:436-441, 470-490, 673, 684` | An agent counts as "ready" only if `~/.local/state/omarchy/agents/usage/<id>.json` has `"ready": true` (written by the dragos.agents/omarchy.agents collectors). | No agent rows, prompt rows or help rows appear. | Ready = the agent's binary is on PATH; the usage file stays as an optional extra signal. |
| 9 | `OmarchySearch.cpp:496-500` | Agent icons come from `~/.config/omarchy/plugins/dragos.agents/assets` or `/usr/share/omarchy/shell/plugins/omarchy.agents/assets`. | Falls back to the `utilities-terminal` icon. | Embed the SVGs (as `BuiltinIcons` already does with `#embed`). |
| 10 | `OmarchySearch.cpp:541-610`; `scrollOverview.cpp:8026-8050`; `main.cpp:1239` | The default agent is read from and written to `~/.config/omarchy/defaults/agent` (Ctrl x2). | Never marked. If an agent row did appear, Ctrl x2 would create `~/.config/omarchy/defaults/`. | Use `~/.config/hyprdrive/default-agent` or a config key; mirror to the Omarchy file only when detected. |
| 11 | `OmarchySearch.cpp:1030,1052-1095` | Menu `when:` predicates (`omarchy-pkg-present`, `omarchy-toggle-enabled`, `~/.config/omarchy/themes`, `/etc/mkinitcpio.conf.d/omarchy_resume.conf`). | Only reached when a menu file exists; otherwise inert. | Keep as is (Omarchy-only path). |
| 12 | `Config.cpp:891-1062, 953-973` | Palette comes from `$XDG_STATE_HOME/omarchy/current/theme/colors.toml`: background, foreground, muted, accent, selection, urgent, light/dark. | Falls back to misc:background_color; accent is col_highlight, then `general:col.active_border` (`:1181`); foreground is white or near-black depending on luminance; selection is the accent at 0.35. It works, but the colours are approximate. | Add explicit `plugin:hyprdrive:theme:{foreground,accent,selection,urgent,muted}` keys (alpha 0 = derive). Derive from `col.active_border`, `col.inactive_border`, `misc:background_color` and `group:groupbar:text_color`. Optionally a `theme:palette_file` key for colors.toml/matugen. |
| 13 | `Config.cpp:1306-1330` | Dock/search plate opacity defaults to 0.85 × `decoration:inactive_opacity` ("Omarchy default-opacity"), and its colour to the colors.toml background. | Opacity is 0.85 on vanilla; colour comes from `misc:background_color`. OK. | Document it, or use 0.9 as the vanilla default. |
| 14 | `Config.cpp:1229-1290` | The font is `misc:font_family` if it is pinned and not "Sans"; otherwise the first `<string>` in `~/.config/fontconfig/fonts.conf` (that is where `omarchy font set` writes it). | The regex can pick up any `<string>` (an alias or a reject entry), which gives a wrong font; otherwise "monospace". | Add a `plugin:hyprdrive:font` key, then `misc:font_family`, then a real `FcFontMatch("monospace")`. Drop the regex. |
| 15 | `scrollOverview.cpp:7340,7375,7504`; `Dock.cpp:4074`; `ScratchpadExit.cpp:28`; about 41 Private Use Area glyphs in the source | Hard-codes "JetBrainsMono Nerd Font" glyphs for menu icons, the search pill's magnifier, the dock context-menu glyph column and the scratchpad arrow. | Without a Nerd Font installed these render as boxes (tofu). | Check fontconfig for any Nerd/Symbols font at init. Otherwise use embedded SVG glyphs (the `BuiltinIcons` path) or symbolic icon-theme names. |
| 16 | `AppSearch.cpp:954-966`; `Config.cpp:753-755`; `Dock.cpp:956,1079,1132`; `DockStacks.cpp:1901-1903` | Icon theme for stacks and Trash = `~/.local/state/omarchy/current/theme/icons.theme`; `dock:stack_icon_theme` defaults to `"omarchy"`. | The name comes back empty, so the GTK theme is used. Silent and correct, but the key name is wrong for vanilla. | Make `"auto"` the default (Omarchy if detected, else GTK) and keep `"omarchy"` as an alias. |
| 17 | `Dock.cpp:3826, 3923-3934` | The dock's "App Icon" context row runs `/usr/bin/qs -p /usr/share/omarchy/shell ipc call dragos.hyprdrive icons <id>`. | The overview closes first, then nothing happens (the spawn fails, or on fedora `qs` hits a shell that is not running). The row does nothing. | Hide it without Omarchy, or launch the native settings app (B1) on its Icons pane. `hdicons` itself has no Omarchy code. |
| 18 | `omarchy-plugin/bin/hd-layout-cycle:22,52` | Super+L cycle state goes to `~/.local/state/omarchy/workspace-layouts`, which Omarchy's `workspace-layouts.lua` replays on parse; it then runs `omarchy-notification-send`. | The layout works live, but nothing replays it, so it is lost on reload or reboot. The notify call fails at the end (only a non-zero exit). | Write `~/.config/hypr/hyprdrive/45-workspace-layouts.lua` (sourced by the loader), or persist the layout in the plugin; use `notify-send`. **Done:** `45-workspace-layouts.lua` + `notify-send` (fc3c05f); the script is installed as `$PREFIX/bin/hyprdrive-layout-cycle`, notifies only when a daemon owns `org.freedesktop.Notifications`, and `mosaic:cycle_bind = auto` is Super+L on plain Hyprland too (`scripts/layout_cycle_test.sh`). |
| 19 | `omarchy-plugin/bin/hdpanel:173, 279-296, 327-335, 489-491` | When animations are turned back on, `OMARCHY_ANIM_LEAVES` re-applies Omarchy's looknfeel animation settings, which use Omarchy-named beziers (`easeOutQuint`, `almostLinear`, `quick`). | On vanilla those bezier names are undefined, so expect config errors or a wrong animation tree. | Snapshot `hyprctl animations -j` before disabling and restore that snapshot. |
| 20 | `hdpanel:517-560` (Mosaic) | `hl.unbind("SUPER + L")` and the SUPER+arrow binds assume Omarchy's bindings. | Silently replaces whatever the user has on those chords. | Make the chords configurable; skip by default when not on Omarchy. |
| 21 | `manifest.json`; `scripts/manifest_check.py` (inside `make check`); `hyprpm.toml` (`name = "Hyprdrive-Omarchy"`, "for Omarchy") | Omarchy marketplace packaging. | Harmless to the build. hyprpm runs `make all` but no install step, so there are no fragments (SUPER tap and default keys still work) and `scratchpad-symbolic.svg` is not next to the .so (`Scratchpad.cpp:118-128`). | Native `hyprpm.toml`; `make install` without the panel; drop `manifest_check` from the native `check`; a hyprpm-friendly fallback for the SVG asset (embed it). |

### B. Omarchy-only features with no sensible native equivalent

Hide these when Omarchy is not detected:

1. **The settings panel** (`omarchy-plugin/Panel.qml`, `HyprdrivePanel.qml`). It imports `qs.Commons`/`qs.Ui` from the Omarchy shell (`Panel.qml:6-7`), its IPC handler is at `:65`, and it runs `hdpanel` from `~/.config/omarchy/plugins/...` (`:60`). It cannot run outside the Omarchy shell.
   - Native route: commit **6b50d85** ("the settings app is gone") deleted a standalone Quickshell settings app: `config/quickshell/hyprdrive-settings.qml`, `modules/hyprdrive/*Pane.qml`, the `.desktop` file and `35-settings-app.lua`.
   - Revive it as the native settings app, backed by the JSON CLIs that are already independent of Omarchy (`hdpanel`, `hdicons`).
   - `scripts/hdctl.py` and `theme-sync.py` (matugen/ii era) are leftovers from that app and should be retired or merged.
2. **Omarchy menu browsing**: drilling into submenus, `when:` predicates, extension merging. Keep it behind detection; vanilla gets the small "System" source from A5.
3. **The Omarchy default agent** (A10): the shared state with `omarchy agent`.
4. **Agent readiness and usage from the agents plugins** (A8): keep it as an optional extra signal.
5. **Matching Omarchy's theme on `omarchy theme set`** through colors.toml and icons.theme. The reload hook (`main.cpp:2123`) is generic and stays.
6. **Mosaic's takeover of Omarchy's Super+L toggle**, and persistence in Omarchy's workspace-layouts directory.

### C. Already generic: no change needed

- **uwsm-app launching** (`Launch.hpp:29-60`): only used when the compositor's cgroup is `wayland-wm@` and `uwsm-app` is on PATH.
- **ScratchpadExit's bar strip** (`ScratchpadExit.cpp:219-330`): scans any TOP/OVERLAY layer surface (Waybar shm or a dmabuf bar).
- **`quickshell:screenCorners`** (`OverviewChrome.hpp:82`): an ii namespace, and the absence is handled.
- **Screensaver class check** (`OverviewInternal.hpp:1154`): a no-op without Omarchy.
- **Passthrough of global keys** (`scrollOverview.cpp:10532+`): reads the live bind table.
- **`recentFiles` `.config/omarchy` entry** (`OmarchySearch.cpp:1935`): only listed if it exists.
- **Webapp detection** (`AppSearch.cpp:719`, `AppInfo.cpp:36`): harmless.
- **Search providers via gsettings**: degrades to alphabetical order.
- **Sushi, `fd`, `wl-copy`, `xdg-open`, the FileManager1 D-Bus call**: freedesktop, not Omarchy.
- **Close animation** (`scrollOverview.cpp:5146`): reads the live `windowsOut` animation.
- **`hdicons`**: no Omarchy references.
- **Comments only**: the remaining `omarchy` mentions in `scrollOverview.cpp`, `Dock.cpp`, `Spring.cpp`, `Mosaic.cpp` and `HotCorner*.hpp`.

### D. Prioritised work list

**P0 – it must load and not error on vanilla**
1. Add `Integration::omarchy()` detection in one place: `plugin:hyprdrive:integration = auto|omarchy|none`, plus an env force-off such as `HYPRDRIVE_NO_OMARCHY=1`. `auto` checks `command -v omarchy` and `~/.local/state/omarchy/current`. The env/config override is required for honest testing on fedora (see the caveat at the top). Route items A4–A11, A16–A17 and section B through it.
2. Fix `25-rules.lua` (A1): use `hl.window_rule`, or guard with `if o then`. First, confirm in a headless 0.56 instance how a Lua error inside a required file affects the rest of `hyprland.lua`.
3. Native install (A3, A21): `make install` skips the Omarchy panel unless detected, plus a native `hyprpm.toml`. Embed `scratchpad-symbolic.svg`. Drop the dev path in `00-plugin.lua` (A2).

**P1 – features that do nothing or look wrong**

4. Search column 0 (A5, A6): a "System" source with native commands; title by integration; never show rows for `omarchy-*` commands that don't exist.
5. Agents (A7–A9): a terminal-launch template, readiness from PATH, embedded icons, so the AI column works on vanilla.
6. Nerd Font fallback (A15): detect the font, then use embedded SVG glyphs.
7. Dock "App Icon" row (A17): hide it, or point it at the native settings app.

**P2 – theming quality**

8. Explicit theme keys with Hyprland-derived defaults (A12, A13).
9. A proper font resolver (A14).
10. `stack_icon_theme = auto` (A16).

**P3 – settings and Mosaic**

11. Revive the standalone Quickshell settings app from 6b50d85 on top of `hdpanel`/`hdicons` (B1). Retire `hdctl.py` and `theme-sync.py`.
12. `hdpanel` animation restore from a snapshot instead of `OMARCHY_ANIM_LEAVES` (A19). Configurable Mosaic chords (A20). `hd-layout-cycle` with its own persistence fragment and `notify-send` (A18).
13. Default agent in Hyprdrive's own state, mirrored to Omarchy's file when detected (A10).

**P4 – packaging and docs**

14. Rename the repo, README and `hyprpm.toml` for the native build (A21). Keep `manifest.json` and `manifest_check.py` only on the Omarchy side.