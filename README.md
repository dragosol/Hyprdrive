# ScrollOverview
ScrollOverview is an overview plugin like Gnome, KDE or wf.
  
![ScrollOverview](https://github.com/user-attachments/assets/e89df9d2-9800-4268-9929-239ad9bc3a54)
  
## Config
A great start to configure this plugin would be adding this code to the `plugin` section of your hyprland configuration file:  
```ini
# .config/hypr/hyprland.conf
plugin {
    scrolloverview {
        gesture_distance = 300 # how far is the "max" for the gesture

        scrolling {
            scroll_moves_up_down = true
            default_zoom = 0.5
        }
    }
}
```

### Properties

| property | type | description | default |
| --- | --- | --- | --- |
|gesture_distance | number | how far is the max for the gesture | `300`|

#### Subcategory `scrolling`

Applies to the only overview implementation used by this plugin
| property | type | description | default |
| --- | --- | --- | --- |
| scroll_moves_up_down | bool | if enabled, scrolling will move workspaces up/down instead of zooming | true |
| default_zoom | float | default zoom out value, [0.1 - 0.9] | 0.5 |


### Keywords

| name | description | arguments |
| -- | -- | -- | 
| scrolloverview-gesture | same as gesture, but for ScrollOverview gestures. Supports: `expo`. | Same as gesture |

### Binding
```bash
# hyprland.conf
bind = MODIFIER, KEY, scrolloverview:expo, OPTION
```

Example:  
```bash
# This will toggle ScrollOverview when SUPER+g is pressed
bind = SUPER, g, scrolloverview:expo, toggle
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
