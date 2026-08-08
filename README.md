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

Produces `scrolloverview.so` (the binary keeps the upstream name until the
config-namespace rename). Load it:

```bash
hyprctl plugin load /path/to/scrolloverview.so
```

Or via `hyprpm` pointing at this repository. Configuration lives under
`plugin:scrolloverview:*` for now; the `plugin:hyprdrive:*` rename is planned
alongside a settings UI, automatic theme adoption, and profiles.

### Unload / fallback

```bash
hyprctl plugin unload /path/to/scrolloverview.so
```

If a build misbehaves at login, comment out the `exec-once`/`hyprpm enable` line
in your Hyprland config and log in again — the plugin never patches the
compositor on disk.

## Credit

Hyprdrive started as a fork of
[yayuuu/hyprland-scroll-overview](https://github.com/yayuuu/hyprland-scroll-overview)
and keeps its BSD-3-Clause license. The render model and the overview's ownership
of the workspace render pass come from that excellent codebase; the
mission-control UX, search, dock, and flight animations are this fork's.
