# ScrollOverview

ScrollOverview is an overview plugin like niri.

https://github.com/user-attachments/assets/7ab51651-7901-44d4-b906-357f4c2869c1

## Installation

### Using Hyprpm (recommended)

1. Add the plugin repository:
   ```bash
   hyprpm add https://github.com/yayuuu/hyprland-scroll-overview.git
   ```
2. Build and fetch dependencies:
   ```bash
   hyprpm update
   ```
3. Enable the plugin:
   ```bash
   hyprpm enable scrolloverview
   ```
4. Configure and Enjoy.

## Configuration

### Hyprlang

```ini
# .config/hypr/hyprland.conf
plugin {
    scrolloverview {
        gesture_distance = 300 # how far is the "max" for the gesture
        scale = 0.5 # preferred overview scale
        workspace_gap = 100
        layout = vertical # vertical or horizontal
        wallpaper = 0 # 0: global only, 1: per-workspace only, 2: both
        blur = false # blur only the main overview wallpaper

        shadow {
            enabled = false
            range = 50
            render_power = 3
            color = rgba(1a1a1aee)
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
            gesture_distance = 300, -- how far is the "max" for the gesture
            scale = 0.5, -- preferred overview scale
            workspace_gap = 100,
            layout = "vertical", -- vertical or horizontal
            wallpaper = 0, -- 0: global only, 1: per-workspace only, 2: both
            blur = false, -- blur only the main overview wallpaper

            shadow = {
                enabled = false,
                range = 50,
                render_power = 3,
                color = 0xee1a1a1a,
            },
        },
    },
})
```

In Lua, `shadow.color` must be an integer color value. The Hyprlang-only
`rgba(...)` syntax is not accepted there.

### Properties

| property         | type   | description                                                            | default |
| ---------------- | ------ | ---------------------------------------------------------------------- | ------- |
| gesture_distance | number | how far is the max for the gesture                                     | `200`   |
| scale            | float  | overview scale, [0.1 - 0.9]                                            | `0.5`   |
| workspace_gap    | number | gap between visible workspaces in the overview, in pixels              | `0`     |
| layout           | string | overview layout: `vertical` or `horizontal`                           | `vertical` |
| wallpaper        | int    | wallpaper mode: `0` global only, `1` per-workspace only, `2` both      | `0`     |
| blur             | bool   | blur the main overview wallpaper without blurring workspace wallpapers | `false` |

#### Subcategory `input`

| property | type | description | default |
| --- | --- | --- | --- |
| left_handed | int | swap left and right mouse button actions in overview: `0` disabled, `1` enabled | `input:left_handed` |
| scrolling_mode | int | mouse wheel behavior: `0` layout-aware default, `1` inverted, `2` vertical scroll changes workspace and horizontal scroll changes columns, `3` vertical scroll changes columns and horizontal scroll changes workspace | `0` |
| drag_mode | int | mouse drag behavior: `0` main button drags windows and middle button pans scrolling workspaces, `1` main button pans scrolling workspaces and middle button drags windows | `0` |

#### Subcategory `shadow`

Controls the shadow around each workspace card. `enabled` defaults to `false`; all other unset values fall back to `decoration:shadow:*`.
| property | type | description | default |
| --- | --- | --- | --- |
| enabled | bool | draw a shadow around each workspace card | false |
| range | int | shadow range in layout px | `decoration:shadow:range` |
| render_power | int | shadow falloff power | `decoration:shadow:render_power` |
| color | color | shadow color | `decoration:shadow:color` |

### Keywords

| name                   | description                                                             | arguments       |
| ---------------------- | ----------------------------------------------------------------------- | --------------- |
| scrolloverview-gesture | same as gesture, but for ScrollOverview gestures. Supports: `overview`. | Same as gesture |

### Binding

#### Hyprlang

```bash
# hyprland.conf
bind = MODIFIER, KEY, scrolloverview:overview, OPTION
```

Example:

```bash
# This will toggle ScrollOverview when SUPER+g is pressed
bind = SUPER, g, scrolloverview:overview, toggle
```

#### Lua

```lua
-- hyprland.lua
hl.bind("SUPER + g", function()
    hl.plugin.scrolloverview.overview("toggle")
end)
```

`hl.plugin.scrolloverview.overview("toggle")` returns a dispatcher function
accepted by `hl.dispatch()` and binds. When called from inside a Lua keybind
callback, it dispatches immediately.

### Other Lua Examples

Set layout per monitor before opening the overview:

```lua
hl.bind(mainMod .. " + Tab", function()
    local monitor = hl.get_active_monitor()
    local layout = monitor and monitor.name == "DP-1" and "vertical" or "horizontal"
    hl.config({ plugin = { scrolloverview = { layout = layout } } })
    hl.plugin.scrolloverview.overview("toggle")
end)
```

Here are a list of options you can use:  
| option | description |
| --- | --- |
toggle | displays if hidden, hide if displayed
select | selects the hovered desktop
off | hides the overview
disable | same as `off`
on | displays the overview
enable | same as `on`

### Supported plugins

- `hyprbars`
