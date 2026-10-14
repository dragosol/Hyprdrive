## Upstream Hyprdrive vs. the hyprdrive-omarchy fork

**Bottom line:** the fork contains all of upstream's history. Upstream `new-release` HEAD `7431f9f` (2026-08-24, tag `v1.1`) is an ancestor of the fork's HEAD: upstream has 0 commits the fork lacks, and the fork has 260 upstream lacks. So there are no upstream-only fixes. Everything upstream has that the fork doesn't was removed on purpose, mostly in one commit: `6b50d85` (2026-09-03), "Omarchy fork: Hyprland is the theme, the settings app is gone", which deleted 11,071 lines across 37 files.

**Build check:** I built upstream unmodified on fedora in a throwaway clone, `/tmp/hd-upstream-ro/up`, against the 0.56.2 SDK (`PKG_CONFIG_PATH=$HOME/sdk/hyprland-0.56.2/share/pkgconfig`; fedora has no system `hyprland.pc`). `make all` returned 0. The only warnings were deprecated `addConfigKeyword`. symcheck passed (580 symbols), as did keycheck, gen_keys_table, gen_schema (446 entries) and host_tests. I did not load the `.so` in any compositor, and no processes were left running. The clone is still there.

### 1. Upstream's own Quickshell settings app (plus schema, slideshow and monitor countdown)
- **Where it lived:**
  - App: `config/quickshell/hyprdrive-settings.qml` (318 lines) and `config/quickshell/modules/hyprdrive/` (Hd, SchemaPane, SchemaRow, RawEditor, ProfilesPane, MonitorsPane, WallpaperPane, Motion; about 1,570 lines of QML).
  - Launcher and desktop entry: `config/hyprdrive-settings`, `config/hyprdrive-settings.desktop`.
  - Window rule: `config/hyprdrive/35-settings-app.lua` (no_anim, matched by title).
  - Schema: `config/schema/curated.json`, `config/schema/hyprland-descriptions.json`, generated `docs/schema.json` (5,232 lines), `docs/EXTENDING.md`.
  - Slideshow: `config/systemd/hyprdrive-slideshow.{timer,service}`.
- **How it read and wrote settings:** the QML never writes files itself. Every read is a `Process` that prints JSON; every write is a shell-out to `scripts/hdctl.py`.
  - `hdctl schema --live` returns the schema merged with live values from `hyprctl getoption`.
  - `hdctl preview KEY VAL` is `hyprctl keyword` (temporary, used while dragging a slider).
  - `hdctl set` / `unset` / `bulk` are the durable writes. They go through `scripts/fragment.py` (the BEGIN/END raw-snippet marker contract) into one fragment per pane, `~/.config/hypr/hyprdrive/40..45-*.lua`, then reload. Ownership is recorded in `~/.local/state/hyprdrive/settings.json`.
  - `raw` / `raw-write` edit a pane's raw block; `ii-set` writes `~/.config/illogical-impulse/config.json`.
  - Helpers:
    - `hdmon.py`: the monitor change on a 15-second countdown. The previous fragment is saved to disk first; a detached `setsid` watcher reverts it, and `hdmon check` in the launcher reverts any unconfirmed change before the window is drawn.
    - `hdprof.py`: profiles and snapshots.
    - `hdimport.py`: theme import.
    - `hdwall.py`: wallpaper repos and the slideshow tick, via `hyprwall-rotate.sh`.
- **What it needs at runtime:** it is **not standalone**.
  - It imports `qs.services`, `qs.modules.common`, `.widgets` and `.functions`, and uses illogical-impulse widgets throughout: Appearance ×118, StyledText ×54, RippleButton ×18, ContentSection, MaterialSymbol, MaterialTextField, NavigationRail*, MaterialThemeLoader, Config, and others.
  - `install-fragments.sh` copies the QML into `~/.config/quickshell/ii` and skips the app if that directory is missing. The launcher runs `qs -p ~/.config/quickshell/ii/hyprdrive-settings.qml`.
  - Also required: `qs` (Quickshell 0.3), python3, `hyprctl`, the repo checkout at a hard-coded path (`HYPRDRIVE_REPO`, default `~/overview-cpp`), and the ii config / matugen palette for `ii-set`, wallpaper and theme rows.
  - The window class is `org.quickshell` (no app_id override exists in Quickshell 0.3.0), so rules must match by title.
- **Does it build on 0.56.2:** it isn't compiled, and its back end (hdctl, fragment.py, gen_schema) passes `make check` on the 0.56.2 SDK. The QML can't run without an illogical-impulse Quickshell config.
- **Revive for the native version:** yes, but only the architecture:
  - **Worth keeping:** the hdctl/fragment.py CLI back end, the schema-driven panes (`gen_schema.py` generates rows from Config.cpp plus Hyprland option descriptions, so a new key appears automatically), and the hdmon countdown, which is genuinely valuable for a monitors pane.
  - **Needs replacing:** the QML would need its ii widget layer swapped for plain QtQuick.Controls or a small vendored widget set, about 1,600 lines touched. The ii-only paths (ii-set, theme-sync, the matugen wallpaper theming, profile `qs -c ii` restarts) would come out.
  - **Alternative:** the Omarchy panel's back end `omarchy-plugin/bin/hdpanel` (1,079 lines of Python, writing `40-panel.lua` and `35-gestures.lua` plus `~/.local/state/hyprdrive/panel.json`) is mostly shell-agnostic. Its Omarchy-specific bits are the animation-leaf overrides, the Super+L / `hd-layout-cycle` Mosaic bind and `~/.local/state/omarchy/workspace-layouts`. But its QML (`HyprdrivePanel.qml`, 2,610 lines, plus `Schema.js`) imports Omarchy's `qs.Commons` and `qs.Ui`, so it isn't standalone either.
  - **Suggested path:** a standalone Quickshell `ApplicationWindow` built on the fork's `Schema.js`/`hdpanel` (it covers the current feature set: gestures, Mosaic, motion blur, AC/battery profiles, which upstream's schema predates), plus upstream's hdmon countdown if a monitors pane is wanted.
- **Leftovers in the fork:** `scripts/hdctl.py`, `hdmon.py`, `hdprof.py`, `hdwall.py`, `hdimport.py`, `gen_schema.py` and gates `x61`–`x67` still exist, but `docs/schema.json` and the QML are gone and gen_schema is no longer in `make check`. These are effectively dead code; they are the parts to resurrect, or else delete.

### 2. The matugen / illogical-impulse theme-sync path unit
- **Where it lived:** `config/systemd/hyprdrive-theme-sync.path` (watches `~/.local/state/quickshell/user/generated/colors.json`, ii's matugen output) and `hyprdrive-theme-sync.service`, which runs `scripts/theme-sync.py` to regenerate `05-theme-derived.lua` from the palette. Installed by `install-fragments.sh` with `@REPO@` replaced by the checkout path.
- **Builds on 0.56.2:** there's nothing to compile, and `theme-sync.py` is still in the fork's `scripts/`.
- **Revive:** no. It only makes sense on an illogical-impulse/matugen desktop. The fork's replacement is better for any setup: unset plugin keys read Hyprland's live values (`highlightColor`, `themeRounding`, `dockBackgroundColor` in `Config.hpp`), so whatever sets Hyprland's colours themes hyprdrive too. At most, keep an optional "derive from matugen" script.

### 3. Super+1..0 dock hotkeys
- **Where it lived:** `config/hyprdrive/30-keybinds.lua`. It unbound ii's SUPER+digit (both the character and `code:10..19`) and bound `hl.plugin.hyprdrive.hotkey("N")`, `"shift N"` and `"ctrl N"`.
- **Still in the fork's C++:** the `hotkey` dispatcher (`main.cpp`) and the keys `dock:hot_keys`, `dock:hotkeys_overlay`, `dock:hotkeys_show_dock` and `dock:shortcut_timeout` all remain. Only the binds were removed, and `dock:hot_keys` now defaults to `false` (upstream: `true`).
- **Builds on 0.56.2:** yes; it's compiled in both trees.
- **Revive:** cheap and reasonable for the native version, where nothing claims SUPER+digit. Ship the binds as an opt-in fragment or a commented block, and set `dock:hot_keys=true` there. Don't make them the default, since most Hyprland configs use SUPER+digit for workspaces.

### How upstream installed
- **hyprpm:** `hyprpm.toml`, repository "Hyprdrive", builds with `make all`, output `hyprdrive.so`. `commit_pins` only cover Hyprland v0.54.3 and v0.55.0–0.55.4, with no 0.56.x pin. The fork removed the pins and renamed the repository to "Hyprdrive-Omarchy".
- **Manual:**
  - `make all` (build plus checks), then either `hyprctl plugin load /path/hyprdrive.so` or the fragment `00-plugin.lua`, which runs `hl.plugin.load(HOME .. "/overview-cpp/hyprdrive.so")` with a `hyprdrive_loaded()` guard.
  - `scripts/install-fragments.sh` writes the fragments to `~/.config/hypr/hyprdrive` via fragment.py, seeds empty per-pane fragments from the schema, installs the app into ii's Quickshell config and the launcher into `~/.local/bin`, writes the `.desktop` file, enables `hyprdrive-theme-sync.path`, installs the slideshow timer, and runs `hdprof init`.
  - Upstream had no `make install`; the fork added one (installs to `$PREFIX/lib/hyprdrive/hyprdrive.so`, then runs install-fragments).
- **Lua:** upstream already used Lua config (`hl.bind`, `hl.define_submap`, `hl.window_rule`) and kept Hyprlang plus the `scrolloverview` names as deprecated aliases for one release.

### Other things upstream had that the fork lacks
None of these are bug fixes; all are deliberate removals or default changes.
- **Hold-Super window pill:** upstream showed a three-button capsule on a window while Super was held. The fork removed the key tracking in commit `f555c86`. `WindowPill.cpp` is still in the tree but nothing triggers it any more.
- **Overview submap:** upstream's `30-keybinds.lua` defined the `hyprdrive` submap with `mouse:272` and `SUPER + mouse:272` select binds (an Aug-1 fix for the global Super-drag bind eating clicks). The fork's commit `6b50d85` also rewrote `30-keybinds.lua` and the submap block isn't in the diff's added lines. Worth confirming whether the native port still needs it.
- **ii integration:** upstream unbound ii's SUPER+Q close and restored a GNOME-style Alt+F4 close, plus ii-specific rules in `25-rules.lua`. None of this applies to a native setup.
- **Profiles, theme import, wallpaper repos, raw-snippet editor:** these existed only as settings-app panes, covered above.

**Paths:**
- Upstream clone and build log on fedora: `/tmp/hd-upstream-ro/up`, `/tmp/hd-upstream-ro/build.log` (I left both in place)
- Fork, read-only: `/home/dragos/Projects/hyprdrive-omarchy` on the XPS and `~/Projects/hyprdrive-native` on fedora