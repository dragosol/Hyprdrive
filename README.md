# Hyprdrive

A mission-control overview and a full dock for [Hyprland](https://hyprland.org) — one C++ plugin.

> **Status: private development.** Built and validated against Hyprland **0.56.1**
> inside a dedicated VM. Not ready for general use yet.

## What it does

**Overview** (tap Super):

- Mission-control grid of **real compositor-rendered windows** — live frost/blur on
  every tile, static, while animating, while dragging, while scrolling.
- Type-to-search with GNOME parity: installed apps, open windows, and
  `org.gnome.Shell.SearchProvider2` D-Bus providers, refined on every keystroke.
- Workspace strip with dynamic (trailing-empty) workspaces. Dragging a tile over a
  strip cell shrinks it to mini scale; release **teleports the real window
  instantly** — no fly-in, no double image.
- Scroll-wheel workspace stepping, 1:1 trackpad follow with snap, keyboard
  navigation across tiles, results, and desktops.

**Dock**:

- GNOME Dash-to-Dock behavior by window count: launch, focus, cycle, whole-app
  minimize/restore — plus favorites, running dots, notification badges, urgency
  wiggle, autohide with pressure reveal, and app hotkeys.
- Minimize/restore with the GNOME 400 ms shrink-into-the-icon flight; minimized
  windows stay live for previews.
- Hover an icon for a frosted panel of that app's **live** windows — including
  minimized windows and windows on other workspaces.
- Trash and mounted locations, GNOME-style right-click menus, drag-to-pin,
  drag-a-window-to-the-dock to minimize.

## Building

```bash
make all
```

`all` is the build **and** `make check`, which is five things in order:
`scripts/symcheck.sh`, `scripts/keycheck.sh`, both doc generators in `--check`
mode (`gen_keys_table.sh`, `gen_schema.py`) and `scripts/host_tests.sh`. A
successful run therefore ends on the host tests, not on the symcheck line:

```
symcheck: OK -- every undefined symbol has a provider (563 checked)
keycheck: OK -- every config key is read under the current prefix
docs/CONFIG.md is current
docs/schema.json is current (446 entries: 80 plugin, 353 hyprland, 13 curated)
host_tests: drop_table_test OK -- DROP_TABLE OK (0)
host_tests: geometry_test OK -- geometry_test: 94 checks, 0 failed
```

The symbol count moves with the build; what matters is the word `OK`.

An undefined symbol in a plugin is not a link error: `-shared` never complains,
`dlopen` binds lazily, and the compositor dies at the first call that reaches
the missing symbol — minutes later, with no backtrace. Never ship a build whose
symcheck failed. See [CONTRIBUTING.md](CONTRIBUTING.md) for the rest of the
build rules, including the one about deleting `hyprdrive.so` before
rebuilding while the compositor has it mapped.

Load it:

```bash
hyprctl plugin load /path/to/hyprdrive.so
```

Or via `hyprpm` pointing at this repository.

### Coming from `scrolloverview`

This fork shipped as `scrolloverview` and was renamed to **Hyprdrive**. An
existing config keeps working for **one release** and needs no edits today:

| old | new |
| --- | --- |
| `scrolloverview.so` | `hyprdrive.so` |
| `plugin:scrolloverview:<key>` | `plugin:hyprdrive:<key>` |
| `scrolloverview:<dispatcher>` | `hyprdrive:<dispatcher>` |
| `hl.plugin.scrolloverview.*` | `hl.plugin.hyprdrive.*` |
| `scrolloverview-gesture` | `hyprdrive-gesture` |
| `submap = scrolloverview` | `submap = hyprdrive` |
| IPC event `scrolloverview` | IPC event `hyprdrive` (both are emitted) |
| `~/.local/state/scrolloverview/favorites` | `~/.local/state/hyprdrive/favorites` (adopted once, automatically) |
| `$SCROLLOVERVIEW_PROFILE` | `$HYPRDRIVE_PROFILE` |

Every old config key is still registered, and a value set on one is copied onto
its new twin at config reload — the new name wins if both are set. The first old
name a session uses prints one deprecation warning naming it, to stderr and to
`/tmp/hyprdrive-compat.log`; once per session, not once per use. Everything in
this table is removed one release after the rename, so migrate when convenient
rather than when forced.

### Unload / fallback

```bash
hyprctl plugin unload /path/to/hyprdrive.so
```

If a build misbehaves at login, comment out the `exec-once`/`hyprpm enable` line
in your Hyprland config and log in again — the plugin never patches the
compositor on disk.

## Configuration

All 80 keys, with their types, defaults and ranges, are in
**[docs/CONFIG.md](docs/CONFIG.md)** — generated from `Config.cpp` by
`scripts/gen_keys_table.sh`, so it cannot drift from the code.

For a config you intend to edit rather than read, prefer the **fragment layer**
below: it is the surface the settings app writes through, and it is designed so
that hand edits and generated ones can live in the same file. Everything lives
under `plugin:hyprdrive:`, with `input:`, `dock:` and `shadow:`
subsections.

Two defaults differ from the table this fork inherited, and the code was right
both times: `scale` is **0.82** (not 0.5) and `workspace_gap` is **40** (not 0).

### Hyprlang

```ini
# .config/hypr/hyprland.conf
plugin {
    hyprdrive {
        scale = 0.82
        workspace_gap = 40
        layout = vertical      # vertical or horizontal
        wallpaper = 0          # 0 global only, 1 per-workspace only, 2 both

        dock {
            autohide = true
            icon_size = 54
        }

        shadow {
            enabled = false
        }
    }
}
```

### Lua

```lua
-- .config/hypr/hyprland.lua
hl.config({
    plugin = {
        hyprdrive = {
            scale = 0.82,
            workspace_gap = 40,
            layout = "vertical",
            wallpaper = 0,
            dock = { autohide = true, icon_size = 54 },
            shadow = { enabled = false },
        },
    },
})
```

In Lua, colour keys must be an integer colour value or a gradient (Hyprland's
own format). The Hyprlang-only `rgba(...)` syntax is not accepted there.

### Config fragments

Everything above can also live in `~/.config/hypr/hyprdrive/*.lua`, sourced by
`hyprland.lua` in **filename order** — the numeric prefix is the load order, so
theme values land before the binds that reference them:

```
~/.config/hypr/hyprdrive/
    00-plugin.lua         loads hyprdrive.so, defines hyprdrive_loaded()
    05-theme-derived.lua  GENERATED from the wallpaper palette (see below)
    10-theme.lua          colours, frost, shadow
    20-layout.lua         scale, layout, workspace gap
    30-keybinds.lua       the hyprdrive submap and the dock hotkeys
    35-settings-app.lua   window rules the settings app needs to obey the
                          motion law it edits
```

The numbering leaves room on purpose: 00-35 are shipped and hand-editable,
40-45 are written by the settings app.

Each fragment has two regions, split by two marker lines:

```lua
hl.config({ plugin = { hyprdrive = { scale = 0.82 } } })   -- machine-owned

-- BEGIN raw-snippet (hand edits below survive regeneration)
hl.config({ plugin = { hyprdrive = { scale = 0.9 } } })    -- yours
-- END raw-snippet
```

Everything **above** the BEGIN line is regenerated wholesale. Everything
**between** the markers is yours and is carried across verbatim, every time.
The raw block is last on purpose: Lua's last assignment wins, so a line you put
there overrides the generated one above it — which is the only arrangement in
which "your edits survive" also means "your edits take effect".

Install or refresh the shipped set with `scripts/install-fragments.sh`; it
preserves every raw block already on disk. `scripts/fragment.py` is the whole
mechanism (`write`, `raw`, `check`) and it is what the settings app calls.

`.conf` fragments are reserved for the legacy (hyprlang) parser and are skipped
by the Lua loader, which cannot source them.

### Theme adoption

Change your wallpaper and the dock and the overview follow it — no restart, and
nothing to run afterwards.

```
matugen writes the palette     ~/.local/state/quickshell/user/generated/colors.json
  -> hyprdrive-theme-sync.path a systemd --user path unit notices (~170ms)
  -> scripts/theme-sync.py     re-derives 05-theme-derived.lua
  -> hyprctl reload            the dock pill and the strip ring repaint in place
```

`scripts/install-fragments.sh` installs and enables the watch. What is derived,
and from what:

| key | from the palette | what it paints |
| --- | --- | --- |
| `col_highlight` | `primary` | overview: strip selection ring, tile and search selection; dock hover |
| `dock:indicator_color` | `primary` | the running dot under a dock icon |
| `dock:background_color` | `primary_container` | the dock pill's hue |
| `dock:background_opacity` | dark or light | the dock pill's alpha |

Dark or light is decided by the luminance of the palette's `surface`, with the
compositor's live `misc:background_color` as a corroborating vote (logged when
the two disagree) and `general:col.active_border` as the fallback accent when
the palette file is missing or unreadable.

#### Inherit or pin, per key

```
pin  >  derived  >  plugin default
```

`05-theme-derived.lua` sorts before every other fragment, so keeping your own
value for something is just writing it — in `10-theme.lua`, in that file's
raw-snippet block, or in a fragment of your own numbered above `05`. Lua's last
assignment wins and your fragment loads later, so the pin holds while everything
you did not pin keeps adopting around it:

```lua
-- 10-theme.lua, raw-snippet block. The dock keeps GNOME's grey; the overview
-- accent still follows the wallpaper.
if hyprdrive_loaded() then
    hl.config({ plugin = { hyprdrive = { dock = {
        background_color = 0xFFC0BFBC,
    } } } })
end
```

`theme-sync.py` reports which keys it saw pinned, in the generated header and in
`~/.local/state/hyprdrive/theme-sync.log`. That report is documentation only:
the load order decides the outcome whether the scan notices or not.

#### No blur key is derived

`dock:blur_*` already default to `-1` = follow `decoration:blur:*`, so the dock's
frost inherits Hyprland's own blur, live. A derived number there would replace
that inheritance with a snapshot. The one frost value that is derived — the
pill's alpha — is clamped, so no palette can push the pill opaque and lose the
blur behind it.

#### Why the fragment is regenerated rather than written once

Hyprland reloads itself when a config file it has already sourced changes, so
matugen rewriting `hypr/hyprland/colors.lua` re-applies `col_highlight` on its
own. Any fragment sorting after that file wins those reloads — so a derived
fragment that nothing regenerates does not merely fail to help, it freezes the
accent. Measured on the guest, all three ways:

| `05-theme-derived.lua` | after a matugen run |
| --- | --- |
| absent | the overview accent follows the wallpaper; the dock does not |
| stale | the overview accent is frozen at the fragment's value |
| regenerated by theme-sync | both follow, minus whatever you pinned |

`scripts/gates/z10_theme_adopt` is that behaviour asserted in pixels, including
both failure modes above.

## Dispatchers

Five, all under `hyprdrive:`. `overview`, `navigate` and `window` validate
their argument and print the accepted set on a mistake; `minimize` treats
anything that is not `restore` as a minimize, and `hotkey` wants a number. On
the **Lua** path every one of the five is additionally checked against the
argument pattern registered with it (`Config.cpp`), which is the stricter
route.

| dispatcher | argument | default | what it does |
| --- | --- | --- | --- |
| `overview` | `toggle`/`on`/`open`/`enable`/`off`/`close`/`disable`, each optionally followed by a monitor name or `all`; or `select` | `toggle` | Open, close or toggle the overview. `select` commits the selection under the cursor and closes. |
| `navigate` | `left`, `right`, `up`, `down` | — | Move the selection through everything drawn: strip cells, search results, window tiles. |
| `window` | `select`, `close`, `click` | — | Act on the window under the cursor. |
| `minimize` | `window`, `restore` | `window` | Minimize the focused window into the dock, or restore the most recently minimized one. Both go through the dock, so both FLY from and into the icon; nothing teleports. |
| `hotkey` | `overlay`, or `1`–`10` optionally prefixed with `shift ` or `ctrl ` | — | Activate a dock slot the way Dash-to-Dock's `<Super>N` does — `10` is the tenth slot, i.e. `<Super>0`. `ctrl ` launches (a new window of a running app, a start for a stopped one); `shift ` takes `shift_middle_click_action`'s branch; plain activates. `overlay` just draws the slot numbers on the icons. |

Slot numbers are the reference's, not the digits on the keys, and the
accelerators themselves are Hyprland `bind` lines — this plugin does not own a
keybinding store.

### Hyprlang

```bash
# hyprland.conf
bind = SUPER, g, hyprdrive:overview, toggle
bind = SUPER, h, hyprdrive:minimize, window
bind = SUPER, 1, hyprdrive:hotkey, 1
bind = SUPER SHIFT, 1, hyprdrive:hotkey, shift 1
```

### Lua

```lua
-- hyprland.lua
hl.bind("SUPER + g", function() hl.plugin.hyprdrive.overview("toggle all") end)
hl.bind("SUPER + h", function() hl.plugin.hyprdrive.minimize("window") end)
for i = 1, 10 do
    hl.bind("SUPER + " .. (i % 10), hl.plugin.hyprdrive.hotkey(tostring(i)))
end
```

Called from inside a Lua keybind callback these dispatch immediately; called
anywhere else they return a dispatcher function that `hl.dispatch()` and binds
accept. A bad argument is a Lua error, not a silent no-op.

Tapping Super alone toggles the overview by default (`tap_super`, with
`tap_super_timeout_ms` as the longest press still counted as a tap). It is not a
bind — the plugin watches the modifier itself, so a rig that holds Super for a
second is correctly ignored.

### Submap

Defining a `hyprdrive` submap replaces the built-in keyboard navigation.
While the submap is active, ordinary Hyprland binds outside it are not handled
unless they carry `submap_universal`. This is how a click can be given a
compound action.

```ini
# hyprland.conf
submap = hyprdrive
    bind = , left,   hyprdrive:navigate, left
    bind = , right,  hyprdrive:navigate, right
    bind = , up,     hyprdrive:navigate, up
    bind = , down,   hyprdrive:navigate, down
    bind = , return, hyprdrive:overview, select
    bind = , escape, hyprdrive:overview, off
    bind = , mouse:272, hyprdrive:overview, select
    bind = , mouse:274, hyprdrive:window, close
submap = reset
```

```lua
-- hyprland.lua
hl.define_submap("hyprdrive", function()
    hl.bind("left",   hl.plugin.hyprdrive.navigate("left"))
    hl.bind("right",  hl.plugin.hyprdrive.navigate("right"))
    hl.bind("up",     hl.plugin.hyprdrive.navigate("up"))
    hl.bind("down",   hl.plugin.hyprdrive.navigate("down"))
    hl.bind("return", hl.plugin.hyprdrive.overview("select"))
    hl.bind("escape", hl.plugin.hyprdrive.overview("off"))
    hl.bind("mouse:272", function()
        hl.plugin.hyprdrive.overview("select")
        hl.plugin.hyprdrive.window("select")
        hl.plugin.hyprdrive.overview("off")
    end, { mouse = true })
    hl.bind("mouse:274", hl.plugin.hyprdrive.window("close"), { mouse = true })
end)
```

A submap that binds no keys leaves the keyboard to the plugin: the overview
only steps aside for a submap that actually claims keys, so a submap defined
purely for the mouse does not kill the arrow keys.

### Trackpad gesture

```ini
# hyprland.conf
hyprdrive-gesture = 3, up, overview               # 3-finger up swipe
hyprdrive-gesture = 4, up, overview, mod:SUPER, scale:1.5
hyprdrive-gesture = 4, up, overview, disable_inhibit
hyprdrive-gesture = 3, up, unset                  # remove one
```

```lua
-- hyprland.lua
hl.plugin.hyprdrive.gesture({ fingers = 3, direction = "vertical" })
hl.plugin.hyprdrive.gesture({ fingers = 4, direction = "vertical", mod = "SUPER", scale = 1.5 })
hl.plugin.hyprdrive.gesture({ fingers = 3, direction = "vertical", action = "unset" })
```

`gesture_distance` is how far the swipe has to travel to count as a full one.

## The settings app

`hyprdrive-settings` is one window for the overview, the dock, the compositor,
the blur and the shell. It is QML hosted by quickshell, installed alongside
illogical-impulse's own settings window and built from its widgets -- never
inside the plugin, so a settings crash cannot take the session with it.

```sh
scripts/install-fragments.sh      # fragments, theme-sync units, and the app
hyprdrive-settings                # or the desktop entry
```

It renders from **`docs/schema.json`**, which is generated:

| source | what it contributes | generated by |
| --- | --- | --- |
| `Config.cpp` | the 80 `plugin:hyprdrive:*` keys | `scripts/lib/configkeys.py` (the same parser as `docs/CONFIG.md`) |
| `config/schema/hyprland-descriptions.json` | 353 compositor options with types, ranges and enums | `gen_schema.py --refresh-hyprland` off a live `hyprctl descriptions -j` |
| `config/schema/curated.json` | panes, routes, per-key overrides, ii knobs, wallpaper entries | hand-written |

So **adding an option is a row, never a QML file**. `make all` fails if the
schema drifts from `Config.cpp`.

### How a value is applied

- **Preview** -- dragging a slider writes live and nothing else. It is not
  durable on purpose: a live write is discarded by the next `hyprctl reload`,
  and it lands after the config parse, so it would beat a pin.
- **Commit** -- letting go writes the pane's fragment through `scripts/fragment.py`
  (temp file + rename) and reloads. That is the only durable path, and
  `scripts/hdctl.py` is the only thing that walks it.
- **qs-restart** -- the Quickshell pane writes ii's `config.json`; quickshell
  reloads itself.

Each pane owns one fragment (`40-hyprland`, `41-blur`, `42-dock`, `43-overview`,
`45-monitors`). They all sort **after** `05-theme-derived.lua`, which is what
makes setting a theme-derived key a **pin**: the app writes the key, the fragment
loads later, and Lua's last assignment wins. Unsetting the row removes it and the
value goes back to following the wallpaper. There is no second mechanism, and the
app never touches `05-theme-derived.lua`.

### Raw snippets

Every fragment-backed pane has a text area over exactly that fragment's raw
block. Lines there survive every regeneration and, because the block sits last,
they win over the generated values above them. On the Blur pane that fans out
without naming anything: all six `dock:blur_*` keys default to `-1` = follow
`decoration:blur:*`, so one line reaches the dock pill, the strip cells and the
overview panels.

Turning blur **off** is only available there. The switch is deliberately absent:
frost is on everywhere, and the raw block is where a deliberate exception goes.

### Monitors

Mode, refresh, scale and position per output, and every change is on a
fifteen-second leash. The previous fragment is fsynced to disk *before* the new
one is applied, and two independent things can put it back: a `setsid` watcher
that outlives the app, and `hdmon check`, which the launcher runs before the
window is drawn. Kill the app, kill the watcher, pull the plug -- the next time
anything opens the settings, an unconfirmed monitor change is undone.

### Profiles

Every file the settings app can write is under a git repository at
`~/.local/state/hyprdrive/profiles`: the fragments, what the app owns
(`settings.json`), and illogical-impulse's `config.json` -- which is in because
the app writes it and because the **wallpaper** lives there, so a restored
profile brings back the picture the accents were derived from. The matugen
palette is deliberately out: it is derived from the wallpaper, and snapshotting a
derivation next to its input is how the two get to disagree.

```sh
scripts/hdprof.py status          # what has changed since the last snapshot
scripts/hdprof.py revert          # put it back, reload, restart the shell if ii moved
scripts/hdprof.py save nord       # a profile is a git tag on a snapshot
scripts/hdprof.py apply nord
```

Snapshots are taken **before**, never after -- automatically by a theme import,
by `hdctl bulk`, and by a monitor change, all through one function. So `HEAD` is
always the surface as it was before the last risky thing, the difference between
`HEAD` and the files on disk is what you might want to undo, and `revert` needs
no argument. There are no remotes and nothing to push.

An apply that dies halfway leaves a pending record, and `hdprof check` -- which
the launcher runs before the window is drawn, next to `hdmon check` -- puts it
back. Same shape as the monitor countdown, for the same reason: the process that
was supposed to clean up is the one that died.

### Importing a theme

```sh
scripts/hdimport.py preview ~/themes/nord.conf     # every key, old -> new
scripts/hdimport.py apply   ~/themes/nord.conf     # behind a snapshot, always
```

A hyprland.conf-style file is parsed with four rules (`name {`, `}`,
`key = value`, `$var = value`) and every assignment is looked up in the schema,
which knows all 446 legal keys -- including the plugin's, so a
`plugin { hyprdrive { dock { ... } } }` block lands on the Dock pane. A `locked`
row stays locked against a file: `decoration:blur:enabled = false` is refused
with its reason printed, because the frost rule does not become negotiable by
arriving in a theme.

Everything else -- binds, `exec-once`, window rules, keys from another Hyprland
version -- is kept **verbatim** in the Hyprland pane's raw snippet, inside a Lua
long-bracket string whose bracket level is computed from the payload so a theme
containing `]]` cannot close it early. Those lines are **inert**: this session's
config is Lua, the fragments are Lua, and 0.56 has no `hl.keyword` and no
`hl.source` to hand a hyprlang line to. Nothing is translated and nothing is
dropped; turning one into `hl.bind(...)` is a person's decision.

### Wallpapers

A repository is a directory, and a remote one is a directory git put there.

```sh
scripts/hdwall.py repo-add nord https://github.com/somebody/wallpapers
scripts/hdwall.py repo-pull nord          # clone and pull only -- never pushes
scripts/hdwall.py set nord/aurora.jpg     # the palette follows
```

Mode, interval, the active repository and "the theme follows the wallpaper" are
schema rows on the Wallpaper pane. The slideshow timer fires once a minute and
reads them on every tick, so changing the interval restarts nothing. An `.mp4` is
a wallpaper like any other: mpvpaper draws it, ii's config still records one
wallpaper path, and the palette comes from a frame `ffmpeg` pulls a second in.

It is all `scripts/hyprwall-rotate.sh` underneath -- extended, not replaced. Its
default stays palette-neutral (an unattended rotation must not re-theme the
desktop) and `THEME=1` is the opt-in; the pane's own swaps take the `THEME` path,
because a swap somebody just asked for is exactly when the accents should follow.

### Adding a setting

**[docs/EXTENDING.md](docs/EXTENDING.md)** -- what a schema row's fields mean,
what each pane does with one, what every apply-strategy does, and a worked
example of a row added end to end (`wallpaper.interval`, commit `de174db`: one
row, one `gen_schema.py`, no QML).

## Credit

Hyprdrive started as a fork of
[yayuuu/hyprland-scroll-overview](https://github.com/yayuuu/hyprland-scroll-overview)
and keeps its BSD-3-Clause license. The render model and the overview's ownership
of the workspace render pass come from that excellent codebase; the
mission-control UX, search, dock, and flight animations are this fork's.
