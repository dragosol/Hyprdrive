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
if hl.plugin and hl.plugin.scrolloverview then
    hl.plugin.scrolloverview.configure({
        gesture_distance = 300, -- how far is the "max" for the gesture
        scale = 0.5, -- preferred overview scale
        workspace_gap = 100,
        wallpaper = 0, -- 0: global only, 1: per-workspace only, 2: both
        blur = false, -- blur only the main overview wallpaper

        shadow = {
            enabled = false,
            range = 50,
            render_power = 3,
            color = 0xee1a1a1a,
        },
    })
end
```

In Lua, `shadow.color` must be an integer color value. The Hyprlang-only
`rgba(...)` syntax is not accepted there.

### Properties

| property         | type   | description                                                            | default |
| ---------------- | ------ | ---------------------------------------------------------------------- | ------- |
| gesture_distance | number | how far is the max for the gesture                                     | `200`   |
| scale            | float  | overview scale, [0.1 - 0.9]                                            | `0.5`   |
| workspace_gap    | number | gap between visible workspaces in the overview, in pixels              | `0`     |
| wallpaper        | int    | wallpaper mode: `0` global only, `1` per-workspace only, `2` both      | `0`     |
| blur             | bool   | blur the main overview wallpaper without blurring workspace wallpapers | `false` |

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
    if hl.plugin and hl.plugin.scrolloverview then
        hl.plugin.scrolloverview.overview("toggle")
    end
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
