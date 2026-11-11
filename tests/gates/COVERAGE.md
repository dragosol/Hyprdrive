# Behaviour gates: what they cover

The designed behaviours come from the owner's list (memory file
`project_hyprdrive_designed_behaviours.md`, compiled 2026-11-10; dates are his
messages). Each row is one behaviour. A gate named here asserts it on the
headless rig (`tests/gates/run.sh <gate>`); "partly" means the gate asserts
the part named, not all of the row. "Not covered" says why.

Run all: `make gates` (or `tests/gates/run.sh`). Each gate's header comment
lists its asserts and the control that makes it fail.

Covered: **33 of 72** rows (27 fully, 6 partly); 39 not covered, each with its reason.

## Mosaic (pure)

| behaviour | gate |
| --- | --- |
| Windows cluster tight, centred on the screen, gaps = theme gaps only [10-14..11-02] | `mosaic` (2: bounding box centred +-2 px, every nearest neighbour 14 px) |
| Wide gaps that leave a window off-screen are a bug | partly: `mosaic` (2, nearest-neighbour gap) |
| Opening a window NEVER resizes existing windows [10-14] | `mosaic` (1) |
| New windows open at their remembered size [11-04] | `mosaic` (3) |
| ... nearest the cursor [11-04] (`spawn_at_cursor`) | `mosaic` (4: pointer top-left / bottom-right) |
| Remembered size logged only from PURE mosaic, never a shrunk/hybrid size [10-15] | partly: `mosaic_hybrid` (2: the sizes after tiling are the pure ones); not covered: a size changed while tiled must not be remembered (needs a reopen after a hybrid resize; next batch) |
| Others stay still while one window is drag-resized; rearrange after release [10-14] | not covered: needs a sampled drag-resize with the rig pointer (corner hit-target positions); next batch |
| Keyboard resize (Super +/-) may rearrange live [10-14] | not covered: the binds are Omarchy/user config, not in the vanilla rig config |
| Resize has a CALCULATED LIMIT; past it the desktop darkens and drops to hybrid [10-14] | not covered: the darkening is a pixel effect during a live drag; the limit needs a drag past it (next batch) |
| Super+arrow focus and Super+direction/drag swap as in dwindle [10-14, 10-16, 10-24] | not covered: focus_binds = auto is Omarchy-only; next batch with explicit binds |
| Drag to the cluster centre puts it in the centre; any side is a valid drop [10-16, 10-27] | not covered: Super+drag drop targets, next batch |
| Corner resize always available; Super+right-drag resizes [10-11, 10-27] | not covered: as above |
| Dragging past the screen edge expands only as far as the cursor moves [10-27] | not covered: as above |
| Floating arrivals join the mosaic unless tagged `hyprdrive-float`; Sushi never rearranges [10-14, 10-28] | not covered: needs a floating-by-rule fixture + a tagged one (easy next) |
| General option "never load windows in floating mode" (`general:open_tiled`) [11-10] | not covered: next batch |
| Super+T toggles a fixed-size window between tiled-at-own-size and floating [11-10] | `own_size_tile` (older gate, still run by `run.sh`) |
| Spawn animation matches dwindle's (right size from frame one) [10-29] | not covered: needs a filmed first frame (wf-recorder); a one-shot grim returns stale frames |
| "Maximize from dock" keeps its own animation [10-29] | not covered: motion |

## Hybrid tiling

| behaviour | gate |
| --- | --- |
| Entered when windows no longer fit (infinite canvas off) [10-26] | `mosaic_hybrid` (1) |
| Behaves exactly like dwindle (swap any window incl. the big one) [10-14, 10-24] | partly: `mosaic_hybrid` (1: tiles cover the screen without overlap); swaps not covered |
| Leaves by itself when the pure sizes fit again; sizes and shapes return [10-14, 10-15] | `mosaic_hybrid` (2) |
| A short-lived window must not leave the desktop stuck in tiling [10-15] | `mosaic_hybrid` (3) |
| Never switches to real dwindle [10-11] | `mosaic_hybrid` (4: layout stays mosaic) |
| Super+L cycles scrolling / dwindle / mosaic [10-11] | not covered here: `tests/layout_cycle_test.sh` (host test of the cycle) covers the order; a rig gate is next |

## Infinite canvas

| behaviour | gate |
| --- | --- |
| Off by default; when off, overflow goes to hybrid tiling [10-26] | `mosaic_hybrid` (1, and its control turns the canvas on) |
| Windows spill at their own sizes, none on another | partly: `own_size_tile` (infinite canvas case) |
| Defaults "all directions" + "zoom out to every window" [10-27] | not covered: config defaults are host-tested (`tests/config_defaults_test.py`) |
| Focusing pans into view with the curve; hover pans; cursor carried ON PURPOSE; a pan never turns instant [10-26, 11-01] | not covered: motion over time; needs filmed frames |
| Zoomed out (Super held): hover selects, labels, drag, W closes, screenshots, swipes and Super+scroll switch desktops, edge-push to the next actual desktop [10-27..11-01] | not covered: needs Super held across pointer motion plus pixel checks; next batch for "W closes without leaving zoom" |
| Super+scroll does not pan; panning past the last window changes desktop [10-26, 10-30] | not covered: next batch (`ptr scroll` with Super held) |
| Overhanging windows slide with the switch; no gap between desktops in overview [10-29..11-02] | not covered: motion/pixels during a switch |
| Push-through at an edge: light push = dock only, harder = moves on; no focus under the dock zone [11-09] | not covered: `ptr rel` pushes can drive it; thresholds are tuned values, next batch |

## Focus and attention

| behaviour | gate |
| --- | --- |
| Switching to a window from the overview puts the cursor on it, centred [10-29, 11-09] | `overview` (3: centred unless the click was on it already, as the handoff code says) |
| ... from the dock previews [10-29, 11-09] | not covered: previews have no debug hook; locating them needs pixels |
| A window that opens unprompted does not take focus or the cursor [11-05] | `mosaic` (5) |
| A modal (Steam sign-in) never traps the cursor [11-01] | not covered: needs an XWayland modal fixture |
| Dock ICON click minimizes/restores the app's windows on the active workspace, no cursor move [11-09] | `dock_click` (1-4) |
| Dock PREVIEW click or Ctrl+click focuses [11-09] | not covered: `debug activate` takes no modifiers, previews have no hook |
| Super+key over a dock PREVIEW acts on that window, as over an overview tile [11-11: "if I mouseover a window preview in the dock I should have access to all the same super+keybind functionality as I do in overview"] | `dock_preview_keys` (1: the pane stays while Super is held; 2-3: Super+F there and back, the focused window untouched; 4: between the cells -> the focused window; 5: Super+W closes it, one cell left; 6: `window close` on the last cell, the pane goes); the cells are found with `debug dockmenu` |
| Attention: icon jumps/wiggles, preview darkens "Needs attention", XWayland requests count, pulls focus at most once [11-01, 11-04] | not covered: needs an urgent-hint fixture (wine_state could send DEMANDS_ATTENTION); pixels for the icon; next batch |

## Fullscreen

| behaviour | gate |
| --- | --- |
| Non-game apps leave fullscreen when another window on that desktop is chosen; games stay, the other goes on top [10-30, 10-19] | partly: `x11_state` (B: a game's fullscreen toggles); the choose-another-window rule not covered (next) |
| Going fullscreen moves the app to n if free, else n+1 [11-05..11-09] | `fs_trip` (1, 3, 4) |
| ... reusing an adjacent empty desktop instead of creating one | `fs_trip` (3) |
| Exit puts everything back and removes the desktop it made | `fs_trip` (2, 3; 5, 5b, 6 = the windows' boxes in Mosaic, three windows, hybrid tiling; 5c = a change meanwhile: the normal rules), `fs_cycles` |
| Exit by closing the app while its desktop is off screen (the old "-1" debt) | `fs_move_close` (B), `fs_close_home` (C) |
| Closing an app on its fullscreen desktop removes that desktop and returns to its origin [11-11] | `fs_close_home` (A closed, B killed, D beside, E home gone, F an X11 remap, G the dock's two chips); not driven: the dock's Quit (the same sendClose as A) |
| A fullscreen window moved onto a populated desktop exits fullscreen and stays there [11-11: also by the dock menu, also a game] | `fs_move_close` (A dispatcher on a trip, C dock menu on a trip, D settled by dispatcher, E Mosaic settled by dock menu, G a game; F an empty desktop keeps it) |
| A window opened from a fullscreen app opens beside it, visible at once; the app stays fullscreen | `fs_beside` |
| A plugin reload (`hyprdrive reload`) leaves every fullscreen window fullscreen, on its desktop, trips and debts kept, with Mosaic in the config file, Omarchy blocks renumbering and a disabled panel coming and going; a plain config reload too [11-11] | `reload_blocks` (A the CLI's steps, B `hyprctl reload`, C the trip still goes home after); the client sees one exit + re-entry in the gap (Hyprland's own reload, see FullscreenCarry.hpp) |
| Spam-proof (50 cycles at 1 Hz and at key-repeat speed, ids unique at every sample) | `fs_cycles` |
| All animated; the card slides from UNDER the origin only during the transition | not covered: motion, needs filmed frames |
| Display change removes empty desktops (21,22,28,29,30 -> 1..5), with a trip in flight, shown-empty kept [owner report 11-11] | `display_compact` |
| Returning to a fullscreen game leaves the pointer mapped correctly [10-19, 10-30] | not covered: XWayland pointer mapping needs an X client reading its own pointer (wine_state could; next batch) |
| An X11 client insisting on maximized gets it once; user toggles work during a storm block (3558972) | `x11_state` |

## Overview, strip, dock

| behaviour | gate |
| --- | --- |
| Real windows: open/close leaves every window untouched | `overview` (1: geometry and settled pixels) |
| Grid hover fades border inactive->active; hover zooms a tile with a tooltip, reverses if abandoned [10-16, 11-06] | not covered: pixels over time |
| Super+F works on an overview window, both trees [11-06]; on the HOVERED tile [11-11: "super+f should act on the hovered tile in overview"] | `overview` (2: the focused window's tile; 2b: another tile hovered -> that one, the focused one untouched, and back; over no tile -> the focused window); Omarchy tree: `--so` run of `overview` |
| Strip: Super+hover highlights/grows a desktop [11-06] | not covered: pixels |
| Strip: drag to reorder, renumbered without duplicates [11-06] | `overview` (4; card coordinates measured on the rig) |
| Moving cards pass smaller, underneath the main one [11-06] | not covered: motion |
| Hold a dragged window 1.5 s over another = swap (option, off) [10-13] | not covered: next batch |
| Hot corner toggles overview with a 1 s ripple [10-13] | not covered: off by default; the ripple is pixels (old `x30`-era gates) |
| Backdrop blur source option (off/static/snapshot/live/auto) [11-03] | not covered: pixels |
| Search: click-to-open off by default; selection colour distinguishable; easter egg toggle [10-08, 10-24, 11-04] | not covered here: defaults host-tested (`config_defaults_test.py`); old `g1`, `g5` |
| Dock fan stacks, scrollbar, type-to-filter [10-08] | not covered: old `v4_stacks` (retired VM share) |
| Dock preview pane wraps, concentric corners [10-16] | not covered: pixels |
| Dock context menu entries [10-13, 10-15, 10-30] | not covered: old `x28` (retired VM share) |
| Drives incl. network shares, drive order; file manager option [10-08, 11-04] | not covered: needs mounts |
| Lutris/Wine apps get proper names, icons, menus [11-05] | not covered: needs Lutris desktop files |
| Minimize/restore flight ends with the window at its box | `dock_click` (3) |
| Scratchpad always slides, follows the gesture, motion blur [10-08, 10-16] | not covered: motion |
| Super+scroll through desktops options; Super+D show desktop [10-15, 11-02, 11-10] | not covered: binds are user config; next batch with explicit binds |
| `hyprdrive load|unload|update|reload` CLI [10-24, 11-04] | partly: `lifecycle` (the unload/load the CLI does, three times, no core); the CLI script itself is host-tested (`update_cli_test.py`) |
| "Update available!" marketplace-aware flow [11-04] | not covered: network + Omarchy |
| Speed setting 0 / animations off: frame sources idle at once | `anim_off` |

## The older gates (`scripts/gates/` in the pre-split tree, `hyprdrive-fix-native`)

They drove a retired VM (`/mnt/host` share) and do not run on the headless rig.
Kept where they are; none was deleted. Superseded, fully or in part, by:

| old gate | superseded by |
| --- | --- |
| `y4_click_semantics` (plain dock click stashes the app's windows, second click restores) | `dock_click` -- now scoped to the active desktop [11-09] |
| `v6_dock_ws_scope` (dock click scope per workspace) | `dock_click` (2, 3: the window on desktop 2 is untouched) |
| `x24` (dock-click flow) | partly `dock_click` |
| `zflight_z4_z7` (minimize/restore flights) | partly `dock_click` (3: lands at its box); the flight's motion is not covered |
| `x43_raise` (an overview tile click raises the window) | `overview` (3) |
| `crash_gate` (dangling listener segfault) | partly `lifecycle` (unload/load/exit without a core) |

Not superseded (still only in the old tree): `f3b_*`, `fade_alpha`, `g1`, `g5`,
`hover_overshoot`, `reopen`, `v0_ws_gap_bound`, `v1_icon_entrance`, `v2_*`,
`v3_dock_drag_launch`, `v4_stacks*`, `v5_sushi_*`, `x1_stress`, `x26`, `x28`,
`x30`, `x32_showapps_fresh`, `x34_hotkeys`, `x46_pill_invariant`,
`x47_hover_preview`, `x48_results_band`, `x50_pill_docks`, `x51_text_cache`,
`x53_compat_alias`, `x60`..`x67` (settings app), `y7_drag_glow`, `y8_bounce_once`,
`y9_filter_reveal`, `y11_crossdesk_preview`, `y12_stash_slot_once`, `z1`..`z3`,
`z10_theme_adopt`.
