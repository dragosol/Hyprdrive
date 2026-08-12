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
build rules, including the one about deleting `scrolloverview.so` before
rebuilding while the compositor has it mapped.

Load it:

```bash
hyprctl plugin load /path/to/scrolloverview.so
```

Or via `hyprpm` pointing at this repository. The binary keeps the upstream
`scrolloverview` name, and so does the config namespace, until the rename lands
with the settings work.

### Unload / fallback

```bash
hyprctl plugin unload /path/to/scrolloverview.so
```

If a build misbehaves at login, comment out the `exec-once`/`hyprpm enable` line
in your Hyprland config and log in again — the plugin never patches the
compositor on disk.

## Configuration

All 79 keys, with their types, defaults and ranges, are in
**[docs/CONFIG.md](docs/CONFIG.md)** — generated from `Config.cpp` by
`scripts/gen_keys_table.sh`, so it cannot drift from the code. Everything lives
under `plugin:scrolloverview:`, with `input:`, `dock:` and `shadow:`
subsections.

Two defaults differ from the table this fork inherited, and the code was right
both times: `scale` is **0.82** (not 0.5) and `workspace_gap` is **40** (not 0).

### Hyprlang

```ini
# .config/hypr/hyprland.conf
plugin {
    scrolloverview {
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
        scrolloverview = {
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

## Dispatchers

Five, all under `scrolloverview:`. Each one validates its argument and reports
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
bind = SUPER, g, scrolloverview:overview, toggle
bind = SUPER, h, scrolloverview:minimize, window
bind = SUPER, 1, scrolloverview:hotkey, 1
bind = SUPER SHIFT, 1, scrolloverview:hotkey, shift 1
```

### Lua

```lua
-- hyprland.lua
hl.bind("SUPER + g", function() hl.plugin.scrolloverview.overview("toggle all") end)
hl.bind("SUPER + h", function() hl.plugin.scrolloverview.minimize("window") end)
for i = 1, 10 do
    hl.bind("SUPER + " .. (i % 10), hl.plugin.scrolloverview.hotkey(tostring(i)))
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

Defining a `scrolloverview` submap replaces the built-in keyboard navigation.
While the submap is active, ordinary Hyprland binds outside it are not handled
unless they carry `submap_universal`. This is how a click can be given a
compound action.

```ini
# hyprland.conf
submap = scrolloverview
    bind = , left,   scrolloverview:navigate, left
    bind = , right,  scrolloverview:navigate, right
    bind = , up,     scrolloverview:navigate, up
    bind = , down,   scrolloverview:navigate, down
    bind = , return, scrolloverview:overview, select
    bind = , escape, scrolloverview:overview, off
    bind = , mouse:272, scrolloverview:overview, select
    bind = , mouse:274, scrolloverview:window, close
submap = reset
```

```lua
-- hyprland.lua
hl.define_submap("scrolloverview", function()
    hl.bind("left",   hl.plugin.scrolloverview.navigate("left"))
    hl.bind("right",  hl.plugin.scrolloverview.navigate("right"))
    hl.bind("up",     hl.plugin.scrolloverview.navigate("up"))
    hl.bind("down",   hl.plugin.scrolloverview.navigate("down"))
    hl.bind("return", hl.plugin.scrolloverview.overview("select"))
    hl.bind("escape", hl.plugin.scrolloverview.overview("off"))
    hl.bind("mouse:272", function()
        hl.plugin.scrolloverview.overview("select")
        hl.plugin.scrolloverview.window("select")
        hl.plugin.scrolloverview.overview("off")
    end, { mouse = true })
    hl.bind("mouse:274", hl.plugin.scrolloverview.window("close"), { mouse = true })
end)
```

A submap that binds no keys leaves the keyboard to the plugin: the overview
only steps aside for a submap that actually claims keys, so a submap defined
purely for the mouse does not kill the arrow keys.

### Trackpad gesture

```ini
# hyprland.conf
scrolloverview-gesture = 3, up, overview               # 3-finger up swipe
scrolloverview-gesture = 4, up, overview, mod:SUPER, scale:1.5
scrolloverview-gesture = 4, up, overview, disable_inhibit
scrolloverview-gesture = 3, up, unset                  # remove one
```

```lua
-- hyprland.lua
hl.plugin.scrolloverview.gesture({ fingers = 3, direction = "vertical" })
hl.plugin.scrolloverview.gesture({ fingers = 4, direction = "vertical", mod = "SUPER", scale = 1.5 })
hl.plugin.scrolloverview.gesture({ fingers = 3, direction = "vertical", action = "unset" })
```

`gesture_distance` is how far the swipe has to travel to count as a full one.

## Credit

Hyprdrive started as a fork of
[yayuuu/hyprland-scroll-overview](https://github.com/yayuuu/hyprland-scroll-overview)
and keeps its BSD-3-Clause license. The render model and the overview's ownership
of the workspace render pass come from that excellent codebase; the
mission-control UX, search, dock, and flight animations are this fork's.
