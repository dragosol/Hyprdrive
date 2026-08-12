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

`all` is the build **and** `scripts/symcheck.sh`, and it must end with

```
symcheck: OK -- every undefined symbol has a provider (558 checked)
```

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

All 79 keys, with their types, defaults and ranges, are in
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
```

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

Five, all under `hyprdrive:`. Each one validates its argument and reports
the accepted set on a mistake.

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

## Credit

Hyprdrive started as a fork of
[yayuuu/hyprland-scroll-overview](https://github.com/yayuuu/hyprland-scroll-overview)
and keeps its BSD-3-Clause license. The render model and the overview's ownership
of the workspace render pass come from that excellent codebase; the
mission-control UX, search, dock, and flight animations are this fork's.
