# The `hyprdrive:debug` dispatcher

Diagnostics and test hooks. They are permanent rather than probe builds because
reading the answer out of the running compositor costs nothing when nobody asks.
A topic that reports something sends the report back as the dispatch **error
text**, so `hyprctl dispatch` prints it (and it also goes to the Hyprland log).
`hyprctl eval` drops it.

From a Lua config or `hyprctl` (Hyprland 0.56, Lua):

```sh
hyprctl dispatch 'hl.plugin.hyprdrive.debug("frames")'
hyprctl eval 'hl.dispatch(hl.plugin.hyprdrive.debug("gesture swipe 3 up 400"))'
```

From a hyprlang config: `hyprctl dispatch hyprdrive:debug frames`.

| topic | what it does |
| --- | --- |
| `frames` | why each monitor is repainting right now (cadence, open overview, previews) |
| `mem` | what hyprdrive holds on the GPU, as far as it can count it |
| `motion` | which `animation:curve` preset is in use, sampled |
| `scratchpad` | a click on the overview's Scratchpad cell |
| `type [word]` | sets the open overview's search query (one word: the Lua pattern is `type \S+`) |
| `press <evdev keycode>` | one key through the search's own press handler |
| `activate <class>` | a left click on that app's dock icon |
| `ripple [x y]` | the hot-corner ripple, from the focused monitor's corner or from (x, y) |
| `gesture <script>` | synthetic touchpad gestures (below) |
| `gesture state` | one line: finger model mode, whether a trackpad gesture is active, steps queued and played, overviews open |
| `gesture stop` | drops the queued steps. A gesture already begun stays open, so end it with `swipe end` or `pinch end` |

## `gesture`: trackpad gestures without a touchpad

A headless or nested Hyprland has no touchpad, and `wlr-virtual-pointer` cannot
send a swipe or a pinch. This topic plays synthetic ones into the same entry
points real ones use:

- **`swipe` and `pinch` steps** go to `CInputManager::onSwipe*` and `onPinch*`.
  Those are the functions Hyprland's own touchpad listeners call. That path
  reaches the event bus, where FingerSwipe may swallow the event. It then
  reaches `CTrackpadGestures`, which runs whichever gesture is bound for that
  finger count and direction: the overview, the workspace swipe with its
  detents, the scratchpad, fullscreen/close, or anything else bound with
  `hl.plugin.hyprdrive.gesture{...}`. It ends at the pointer-gestures protocol.
- **`frame` steps** go to FingerSwipe's raw-finger handler, the one
  TouchpadRaw calls for each evdev frame. This is what `gestures:keep_swipe`
  and `gestures:swipe_while_dragging` act on.
- **`hold` and `button` steps** go to the click gestures' touchpad handlers
  (OverviewGesture.cpp `padHold*` / `padButton`). Those are the handlers a
  pointer device's hold signals run, and that the `CInputManager::onMouseButton`
  hook runs for a touchpad's button. A `button` press is then emitted as the
  `input.mouse.button` bus event, where the click gestures, the overview and the
  dock take a press. It is not delivered to a client. Swipe and pinch steps also
  pass through these handlers, as a touchpad's own signals do. This is what
  lets a swipe that starts inside a cancelled hold's grace stop a click.

Bind the gestures first, because a vanilla test config has none. For example:
`hl.plugin.hyprdrive.gesture({ fingers = 3, direction = "up" })`.

### The script

Steps are separated by `;` and run in order from the event loop. `wait` and the
macros' step spacing make a script play over real time, so the compositor draws
the frames in between. A script sent while another is still playing queues
behind it.

| step | meaning |
| --- | --- |
| `swipe begin F` / `swipe update F DX DY` / `swipe end [cancel]` | one libinput swipe event each. DX and DY are libinput delta units (about device px). Up is negative DY |
| `pinch begin F` / `pinch update F SCALE [ROT [DX DY]]` / `pinch end [cancel]` | one pinch event each. SCALE is relative to the begin |
| `frame [button] [ID:X:Y ...]` | one raw touchpad frame: the touches that are down (tracking id, mm) and whether the clickpad button is held. A bare `frame` means every finger has lifted |
| `hold begin F` / `hold end [cancel]` | libinput's hold gesture: F fingers resting, then lifted (`hold end`) or moved or clicked (`cancel`) |
| `button left\|right\|middle down\|up` | one clickpad button edge, from the touchpad |
| `wait MS` | pause |
| `swipe F up\|down\|left\|right DIST [STEPS [MS]] [hold]` | begin, then STEPS updates (default 12, 8 ms apart), then end. `hold` leaves the gesture open |
| `pinch F in\|out [SCALE [STEPS [MS]]] [hold]` | `in`/`out` are the **config** directions `pinchin`/`pinchout`. Hyprland 0.56 maps scale < 1 (fingers closing) to `pinchout`, so `out` runs scale 1 to 0.5 and `in` runs 1 to 2.0 |
| `keep F DIR MM1 MM2 [STEPS [MS]]` | keep_swipe. F fingers swipe MM1 mm. One finger lifts, so libinput cancels its swipe and starts an (F-1)-finger one. The rest travel MM2 mm more, then lift |
| `drag F DIR MM [STEPS [MS]]` | swipe_while_dragging. One finger holds the button, F more (3 or 4) land and travel MM mm, lift, then the button is let go. libinput sends no gesture for this, only frames |
| `click F [MS]` | an F-finger physical click (clickfinger). `hold begin F`, 30 ms, `hold end cancel` (the press cancels the hold). For 1, 2 or 3 fingers the button clickfinger maps them to (left, right, middle) then goes down and comes up MS later (default 40). 4 or more fingers map to no button, so the cancelled hold is all there is, and the click fires after the 80 ms grace |

Errors name the step: `'swipe 3 sideways 10': swipe F up|down|left|right DIST
[STEPS [MS]] [hold]`. The parser is `DebugGestureScript.hpp`.
`scripts/debug_gesture_test.cpp` checks it and runs the `keep` and `drag`
macros through the real FingerSwipeModel.

### Recipes

These were proven headless with `scripts/headless/hl.sh` (`hl.sh gesture '<script>'`
wraps the dispatch):

```sh
# 3-finger overview: scrub half-way, photograph, finish, then close
hl.sh gesture 'swipe 3 up 150 6 10 hold'; hl.sh shot mid.png
hl.sh gesture 'swipe update 3 0 -300; swipe end'      # overview open
hl.sh gesture 'swipe 3 down 400'                      # closed

# desktop swipe (4 fingers bound to action = "workspace"): workspace 1 -> 2
hl.sh gesture 'swipe 4 left 1500 20 8'
# inside the overview the cards follow, with the detent pill on the card
hl.sh gesture 'swipe 4 left 600 20 8 hold'; hl.sh shot detent.png; hl.sh gesture 'swipe end'

# keep_swipe: 1 mm of libinput swipe (0.15 of the open distance) then a lift.
# keep_swipe = true: the overview opens. false: it springs back closed
hl.sh gesture 'keep 3 up 1 10'

# swipe_while_dragging = true: opens the overview. false: nothing happens
hl.sh gesture 'drag 3 up 12'

# 4-finger pinchout bound to fullscreen_on: the focused window goes fullscreen
hl.sh gesture 'pinch 4 out 0.4 15 10'

# click gestures, bound with direction = "click":
#   hl.plugin.hyprdrive.gesture({ fingers = 3, direction = "click", action = "overview" })
#   hl.plugin.hyprdrive.gesture({ fingers = 4, direction = "click", action = "close" })
hl.sh gesture 'click 3'                               # overview opens (again: closes)
hl.sh gesture 'click 4'                               # the focused window closes, 80 ms later
# the 80 ms grace: a cancelled 4-finger hold is also how every 4-finger swipe
# and pinch STARTS. A pinch inside the grace keeps the window...
hl.sh gesture 'hold begin 4; wait 30; hold end cancel; pinch begin 4; pinch update 4 0.95; pinch end cancel'
# ...one that starts after it is too late, and the window closes
hl.sh gesture 'hold begin 4; wait 30; hold end cancel; wait 150; swipe begin 4; swipe end cancel'
# fingers rested and lifted (not cancelled) fire at once; a rest over 800 ms is not a click
hl.sh gesture 'hold begin 4; wait 60; hold end'
hl.sh gesture 'hold begin 4; wait 1000; hold end'     # nothing

hl.sh gesture state
```

Set `HYPRDRIVE_CLICK_LOG=1` in the compositor's environment to log every
click-gesture decision to `/tmp/hyprdrive-click.log`.

What it does not cover: anything that needs libinput's own timing or
acceleration. The deltas and hold durations are taken exactly as given.
