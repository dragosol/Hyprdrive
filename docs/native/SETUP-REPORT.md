I've done all five steps on fedora. The plugin builds, `make check` passes, and it loads into a headless Hyprland that runs as hyprtest, with nothing on a physical monitor or seat. In that test instance the overview opens, accepts typing and clicks, and works on two outputs. The branch is pushed, and fedora can push to GitHub directly. Two things didn't go as planned: the XPS checkout had no uncommitted work to import, and the plugin crashes the compositor when there is no D-Bus session.

**1. hyprtest config is now vanilla**
- **Backup:** `~hyprtest/backup-pre-native-20261014_133456.tar.gz` (53 MB, 65 entries). It covers `.config/hypr`, `omarchy`, `serpantinum`, `uwsm`, `environment.d`, `.bashrc`, `.local/lib/hyprdrive`, `.local/state/hyprdrive` and `.local/share/hyprdrive-old-backup-*`.
- **Moved aside, not deleted,** into `~/.config/hypr/attic-pre-native-20261014_133456/`:
  - the old `hyprdrive/` fragments (00–30), `config/hyprdrive.lua` and `config/serpantinum-translator.lua`
  - `serpantinum.lua.bak`, every `*.bak.*`, and `~/.config/serpantinum/`
  - `~/.config/uwsm/env`, which exported `OMARCHY_PATH` and `/usr/share/omarchy/bin`
- **`hyprland.lua`** now requires only variables, env, autostart, monitors, settings, rules and keybinds.
- **`autostart.lua`:** `serpantinumd start` and `serpantinum-hypr-sync` are commented out with a note.
- **`keybinds.lua`:** 22 Serpantinum binds are commented out (brightness, screenshots, lock, launcher, volume, panels). The two `serpantinum msg workspace` binds were replaced with plain `hl.dsp.focus({workspace=i})` and `hl.dsp.window.move({workspace=i})`.
- **`.bashrc`:** the two Omarchy export lines are commented out.
- **Left alone:** `environment.d/serpantinum.conf` (it only sets PATH), `~/.config/omarchy/`, and `~/.local/bin/serpantinum*`.
- **Check:** `luac -p` passes on every file and `Hyprland --verify-config` says "config ok".

**2. SDK**
- **Location:** `~/sdk/hyprland-0.56.2/{include,share/pkgconfig}`. Run `. ~/sdk/hyprland-0.56.2/env.sh` to set `PKG_CONFIG_PATH`.
- **pkg-config:** `pkg-config --cflags hyprland` gives `-I/home/dragos/sdk/hyprland-0.56.2/include -I…/include/hyprland/protocols -I…/include/hyprland -I…/include/hyprland/src` plus the system deps.
- **The XPS headers didn't work as copied.** Their `src/version.h` records the Arch build's aquamarine 0.15.0, while fedora's Hyprland was built against aquamarine 0.14.0. The plugin refused to load with "[he] Version mismatch". I patched `version.h` to 0.14 (the XPS original is kept as `version.h.xps-orig`).
- **ABI now matches:** fedora's hash is `efb5099…_aq_0.14_hu_0.14_hg_0.5_hc_0.1_hlg_0.6`. Fedora's other deps match its own build: hyprutils 0.14.1, hyprlang 0.6.8, hyprgraphics 0.5.1, hyprcursor 0.1.13.

**3. Repo**
- `~/Projects/hyprdrive-native` on fedora, branch `hyprland-native`, based on `new-release` (7431f9f). Pushed straight from fedora (gh is logged in through the keyring), so no XPS push mirror was needed. Nothing went to `new-release`.
- **The XPS checkout was not dirty.** HEAD is `020c4cdb9df0ec57ebbc4d9ddf5fae092c0be2c4` (v1.9.34) with a clean `git status`, and that commit is already on GitHub (dragosol/hyprdrive-omarchy, `new-release`).
- **The import came from GitHub, not from the XPS.** The permission check blocked piping the XPS working tree to fedora, so fedora fetched 020c4cd and I confirmed the tree is identical (432 files, same as `ls-files -co` on the XPS). The commit message says "clean, no uncommitted changes" instead of "+uncommitted".
- **Commits:**
  - 427c02b: the import
  - acb8451: the harness
  - 89c28e8: harness fixes

**4. Build**
- Run `. ~/sdk/hyprland-0.56.2/env.sh && make hyprdrive.so`. No Makefile changes were needed. Full build takes 46 s with `nice`, with only deprecation warnings (`addConfigKeyword`).
- `make check` passes everything (symcheck, keycheck, gen_keys_table, host_tests, manifest, private_modes, hdicons). None of the checks needed Omarchy.
- Installed to `~hyprtest/.local/lib/hyprdrive/hyprdrive.so` with `scripts/headless/hl.sh install`. I didn't use `make install` because it also installs the Omarchy fragments.

**5. Harness: `scripts/headless/hl.sh`**
- **Commands:**
  - `start [--no-plugin] [--so P] | stop | status`
  - `h <hyprctl args> | eval '<lua>' | overview [arg]`
  - `shot <file> [OUTPUT]`
  - `win [cmd]` (kitty by default)
  - `mon2` (adds HEADLESS-2)
  - `type <text> | tap Super+Tab | down/up <Key>`
  - `ptr move|click|down|up|scroll|drag`
  - `key <wtype args>`, `warp X Y`, `sig`, `log`, `install`
- **Why it nests:** Hyprland 0.56 has no headless-only mode. The `HYPRLAND_HEADLESS_ONLY` variable is set by upstream's tester but the binary never reads it. On its own, the headless backend fails with "no allocator available", and the DRM backend needs a seat session that hyprtest doesn't have.
  - So Hyprland nests inside `mutter --headless --virtual-monitor`, which uses only render nodes and no display modesetting.
  - Hyprland then creates its own HEADLESS-1 at 1920x1080 and turns off the nested window.
  - `LIBSEAT_BACKEND=logind` is pinned so it never opens the card devices directly.
- **Input:**
  - **Keyboard:** a small helper (`vkbd.py`) keeps one virtual keyboard attached for the whole run. Without any keyboard, no window ever gets keyboard focus.
  - **Pointer:** `vptr.py` drives a virtual pointer, which goes through Hyprland's real pointer path.
  - **wtype doesn't work in the overview.** It adds a new keyboard each call, and the overview reacts by closing.
  - **uinput can't work** in this nested setup, because there is no libinput.
- **Proof run:** start, plugin list shows hyprdrive, two kitty windows, overview opened with `hl.dispatch(hl.plugin.hyprdrive.overview("toggle all"))`. Screenshots are in `~/hl-shots/` on fedora; I looked at each one:
  - `proof-2-overview.png`: tiles, workspace strip and dock
  - `proof-3-overview-search.png`: "term" typed into the search with results
  - `04-overview-hover.png`: pointer hover enlarges a tile
  - A click on a tile focused that window and closed the overview.
  - Typing "echo Hello_World!" into kitty worked, and HEADLESS-2 works for multi-monitor.
- **Clean stop:** `stop` exits cleanly and leaves no hyprtest processes. Hyprland itself didn't crash once the session-bus fix below was in. `coredumpctl` run as dragos does list hyprtest's crashes (details only, no core file), and `stop` checks it.

**Problems and open questions**
1. **Plugin bug that crashes the compositor:** in `SearchProviders.cpp`, if `sd_bus_open_user` fails, the search worker exits without being joined. The next overview open then replaces that thread object, which aborts Hyprland. It happened in the first harness run, which had no session bus. A normal login always has one, so the harness now gives Hyprland its own bus. I didn't change plugin code; the fix is to join the old thread before starting a new one in `ensureWorker()`.
2. **Search starts GNOME apps:** on a normal session bus, the overview's search warm-up launched about 30 GNOME search providers (nautilus, firefox, evolution, gnome-software…). The harness bus now allows no service activation. On a vanilla desktop this is real behaviour to decide on.
3. **Omarchy leftovers in the plugin:** search shows an "Omarchy Menu" section because fedora has `/usr/share/omarchy`. The overview also draws plain white outline frames around the main area and the dock. These are the first things to look at in the port.
4. **GPU:** the nested setup renders on the 7900 XTX (mutter picks the boot GPU, not the iGPU). Load is idle-level, but it shares the card with training.
5. **Things I found and fixed along the way:**
   - My helper scripts made python crash with a core dump on every stop (fixed).
   - The core check in `stop` was reading the wrong column and missed those 4 cores (fixed and confirmed).
   - One HEADLESS-2 screenshot came out empty and I couldn't reproduce it.
   - Two Hyprland aborts under hyprtest at 13:35 and 13:43 were my own probes, run without a runtime dir and before the nesting fix.
6. **Other notes:**
   - I installed pywayland 0.4.18 into hyprtest's user Python packages.
   - Hyprland 0.56.2 and aquamarine 0.14 source clones are in `~/src` on fedora, for reference.
   - The "started without start-hyprland" warning is dismissed on purpose: that launcher restarts Hyprland after a crash, which would hide crashes in tests.