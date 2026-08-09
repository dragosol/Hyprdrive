// Z19: this block must be FIRST. m_Value is private in hyprutils, and the
// flight drives the RENDERED box only -- setValueAndWarp moves the GOAL, and
// goal changes configure the client: a ~60-configure storm per flight, whose
// late acks from a slow client (Zen) land after the flight and clobber the
// geometry. The std headers are included clean first so private=public covers
// ONLY the hyprutils header whose guard we claim here; every later inclusion
// is a no-op.
#include <sstream>
#include <functional>
#include <memory>
#include <chrono>
#include <string>
#include <vector>
#include <algorithm>
#include <cmath>
#include <any>
#define private public
#define protected public
#include <hyprutils/animation/AnimatedVariable.hpp>
#undef protected
#undef private

#include "Dock.hpp"

#include "AppSearch.hpp"
#include "globals.hpp"
#include "Config.hpp"
#include "IOverview.hpp"
#include "LauncherEntry.hpp"
#include "Locations.hpp"
#include "Minimize.hpp"
#include "OverviewPassElement.hpp"
#include "OverviewRender.hpp"
#include "Window.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <optional>
#include <ranges>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#define private public
#define protected public
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>
#undef protected
#undef private

// Z16: the flight proxy carries the same card shadow the overview draws. Comes
// AFTER the protected=public block above: this header pulls Renderer/Monitor/
// Window, and if it landed before the block those classes would be defined with
// protected intact and Dock could not reach m_realPosition/m_realSize. These
// helpers used to force the whole ~1900-line OverviewInternal.hpp (and with it
// Dock.hpp, an include knot) into this TU; they now live in their own header.
#include "OverviewChrome.hpp"

namespace ScrollOverview::Dock {

namespace {

// OVERVIEW_CPP_SPEC §13.9 X27. Every proportion below is READ off the reference
// implementation -- the user's own Dash to Dock, `#dashtodockContainer.bottom`
// in its stylesheet.css -- not eyeballed off a screenshot:
//
//   .dash-background          margin-bottom 4, border-radius 24
//   #dashtodockDashContainer  padding 10 (left/right; top and bottom are 0)
//   .dash-item-container      margin 0 2
//   .app-well-app             padding-top 10, padding-bottom 14
//
// The app-well-app's 2px HORIZONTAL padding is deliberately not counted: D2D
// wraps one app per .dash-item-container, so the `:first-child`/`:last-child`
// rules that zero padding-left/right match every item, and the 2px container
// margin is what actually spaces the icons ("we handle them here", per the
// stylesheet's own comment).
//
// (user, 2026-08-03): D2D's 10/14 split is NOT symmetric -- it reserves the extra
// 4px at the bottom for the running dot -- and the icons read as sitting high in
// the pill. Split the same 24px evenly instead, so the icon is equidistant from
// the pill's top and bottom. The total is unchanged, so every X27 proportion
// still measures the same; only the icon's y moves. X31's dot overlays the
// bottom padding when it lands rather than owning it.
// X53. Icon spacing, measured off the host's dash-to-dock -- with ONE
// deliberate divergence, requested directly: the icon sits the SAME distance
// from every pill edge.
//
// The host does NOT do this. Measured off the user's recording, its icon is 18
// from the top, 20 from the bottom and 16 from the sides, because its item
// padding is 10 left / 12 top / 14 bottom and the extra band at the bottom is
// room for the running dot. The user looked at that, correctly saw the icon
// sitting low, and asked for 18 on all four edges instead. So:
//
//   KEPT from the host   icon 54, halo 6 (highlight 66), icon gap 16,
//                        and therefore 4px between adjacent highlights
//   DIVERGES             icon-to-pill is ICON_PAD on every edge, not 10/12/14
//
// Do not "restore parity" here: the asymmetry is the thing that was rejected.
constexpr float HOVER_PAD = 6.F;   // the halo the highlight adds around an icon
constexpr float ICON_GAP  = 16.F;  // icon edge to icon edge, at rest (host's)
constexpr float ICON_PAD  = 14.F;  // icon to pill, EVERY edge (the divergence)

// Derived, so the three numbers above stay the only things anyone edits.
constexpr float HIGHLIGHT_GAP   = ICON_GAP - 2.F * HOVER_PAD;
constexpr float HL_PAD          = ICON_PAD - HOVER_PAD; // highlight to pill, every edge
constexpr float ITEM_MARGIN_X   = ICON_GAP / 2.F;
constexpr float CONTAINER_PAD_X = ICON_PAD - ITEM_MARGIN_X;
constexpr float ITEM_PAD_TOP    = ICON_PAD;
constexpr float ITEM_PAD_BOTTOM = ICON_PAD;
constexpr float EDGE_MARGIN     = 4.F;

// The rule as arithmetic, so a build that breaks it cannot compile.
static_assert(HIGHLIGHT_GAP > 0.F, "X53: a hover highlight must not reach into the icon next to it");
static_assert(2.F * ITEM_MARGIN_X == ICON_GAP, "X53: icon edge to icon edge must be ICON_GAP");
static_assert(CONTAINER_PAD_X + ITEM_MARGIN_X == ICON_PAD, "X53: the outer icons must sit ICON_PAD from the pill's sides");
static_assert(ITEM_PAD_TOP == ICON_PAD && ITEM_PAD_BOTTOM == ICON_PAD, "X53: the icon must sit ICON_PAD from the pill's top and bottom");
static_assert(ITEM_PAD_TOP == ITEM_PAD_BOTTOM, "X53: equidistant top and bottom -- this is the divergence the user asked for");
static_assert(CONTAINER_PAD_X + ITEM_MARGIN_X - HOVER_PAD == HL_PAD, "X53: the highlight therefore clears every pill edge by HL_PAD");

// X25. A preview is as TALL as an icon -- it shares the icon row -- and as wide
// as the window's own aspect makes it. The clamp is what stops one ultrawide or
// one tall-and-thin window from owning the pill; it is not a look, it is a
// bound, which is why it is a constant and not a config key.
constexpr float PREVIEW_MIN_ASPECT = 0.60F;
constexpr float PREVIEW_MAX_ASPECT = 2.20F;

// (user, 2026-08-03) hover highlight and tooltip, read off the GNOME shell the
// user showed: a rounded cell slightly larger than the icon, and a dark plate
// above the dock carrying the app's name.
// X57. The host draws its dash label and its overview window caption with ONE
// style, so this is both of them:
//     .dash-label, .window-caption {
//         background-color rgba(0,0,0,0.9); border 1px rgba(255,255,255,0.1);
//         border-radius 999px; padding 6px 12px; color #ffffff }
// The PILL shape and the 12x6 padding ratio are the host's. The size is the
// user's ("make the tooltips bigger"), and the border comes from Hyprland
// rather than from that stylesheet -- see X56.
constexpr float TOOLTIP_FONT   = 16.F;
constexpr float TOOLTIP_PAD_X  = 16.F;
constexpr float TOOLTIP_PAD_Y  = 9.F;
constexpr float TOOLTIP_BG_A   = 0.90F;
constexpr float TOOLTIP_GAP    = 8.F;

// X28. The app-icon menu. Same font as the tooltip -- it is the same chrome,
// one plate up -- with GNOME's roomier row padding.
constexpr float  MENU_FONT      = 13.F;
constexpr float  MENU_PAD_X     = 14.F;
constexpr float  MENU_ROW_PAD_Y = 7.F;
constexpr float  MENU_RADIUS    = 10.F;
constexpr float  MENU_GAP       = 8.F;
constexpr float  MENU_SEP_H     = 9.F;
constexpr float  MENU_MIN_W     = 170.F;
constexpr size_t MENU_LABEL_MAX = 44; // bytes; window titles are arbitrarily long

// OVERVIEW_CPP_SPEC 13.12 X47. The hover preview panel. Windows' taskbar for
// placement and trigger, this rice for looks: the same frost, the same plate and
// the same house curves the X28 menu already uses, because it is the same class
// of floating chrome one gap above the pill.
constexpr float  PANEL_GAP      = 8.F;   // above the pill, matching MENU_GAP
constexpr float  PANEL_PAD      = 10.F;
constexpr float  PANEL_CELL_H   = 132.F; // logical px, the preview row's height
constexpr float  PANEL_CELL_GAP = 10.F;
constexpr float  PANEL_RADIUS   = 12.F;
constexpr float  PANEL_IN_MS    = 170.F;
constexpr float  PANEL_OUT_MS   = 130.F; // exits ~25% quicker, house rule
constexpr float  PANEL_SLIDE_MS = 160.F; // travel from one icon to the next
// A short hold before the dismissal starts, so crossing the gap between two
// icons does not flicker the panel away and back.
constexpr float  PANEL_GRACE_MS = 180.F;
// ponytail: past this the cells are too narrow to read anyway. Scroll or a
// second row if an app with a dozen windows ever needs them all.
constexpr size_t PANEL_MAX      = 6;

// X31 RUNNING INDICATOR. `running-indicator-style` is DEFAULT in the reference,
// and DEFAULT is not a Dash to Dock drawing at all: appIconIndicators.js's
// RunningIndicatorDefault only adds a css class and leaves GNOME SHELL's own dot
// showing -- `_updateDefaultDot` shows `source._dot`, and only the DOTS style
// ever calls `_hideDefaultDot`. So the shape to match is the SHELL's, read out
// of gnome-shell-dark.css and D2D's `.bottom` override:
//
//   .app-grid-running-dot   height 5, width 5, border-radius 5, #fafafb
//   #dashtodockContainer.bottom ... .app-grid-running-dot   margin-bottom 2
//
// ONE dot, not one per window. The shell's `_dot` is a single actor, and D2D's
// `running1..running4` classes are css hooks the default theme never styles.
// (RICE_PROGRESS.md's "DEFAULT (dots)" is a plural the source does not support.)
// Confirmed against the recording: every dot on the host measures exactly 5px
// wide, and no icon carries two.
//
// The gap between the ICON BOX and the dot, MEASURED, not the css margin-bottom
// above -- that one is the space under the dot. On the host the dot's first
// (antialiased) row lands 2px past the icon's last row, i.e. 1px past the icon
// box, and 2 here put it a pixel low.
constexpr float DOT_MARGIN_B = 1.F;

// X31 NOTIFICATION COUNTER. `.notification-badge` in the reference's own
// stylesheet.css: white on red, padding 0.2em 0.5em, border-radius 1em,
// font-weight bold, margin 2px -- pinned to the icon's TOP-RIGHT, which is the
// St.Bin xAlign END / yAlign START in `_updateNotificationsBadge`.
constexpr float BADGE_PAD_X_EM = 0.5F;
constexpr float BADGE_PAD_Y_EM = 0.2F;
constexpr float BADGE_MARGIN   = 2.F;
constexpr int   BADGE_WEIGHT   = 700; // `font-weight: bold`

// `_updateNotificationBadgeStyle`, followed verbatim rather than converted: the
// host's `font-name` is "Ubuntu 11", points not absolute, so 11 * 0.9 / 0.75,
// then scaled by iconSize / 48. 48 is the SCHEMA default of `dash-max-icon-size`
// -- which is what `get_default_value` reads -- and NOT the user's effective 54.
constexpr float BADGE_FONT_PT      = 11.F;
constexpr float BADGE_FONT_RATIO   = 0.9F;
constexpr float BADGE_DEFAULT_ICON = 48.F;

// X31 URGENT, `dance-urgent-applications` true. The reference's IconAnimator
// (docking.js:2612-2635) runs ONE 3000ms timeline on repeat and sets
// rotation_angle_z = progress < 1/6 ? 15 * sin(progress * 24 * PI) : 0. So the
// icon wiggles for the first 500ms of every 3s and is still for the other 2500,
// two full sine periods per burst (24*PI * 1/6 = 4*PI). One shared clock, so
// two urgent apps wiggle together instead of each on its own phase.
constexpr float WIGGLE_PERIOD_MS = 3000.F;
constexpr float WIGGLE_FRACTION  = 1.F / 6.F;
constexpr float WIGGLE_DEGREES   = 15.F;

constexpr const char* KEY_ENABLED    = "plugin:scrolloverview:dock:enabled";
constexpr const char* KEY_ICON_SIZE  = "plugin:scrolloverview:dock:icon_size";
constexpr const char* KEY_FRACTION   = "plugin:scrolloverview:dock:height_fraction";
constexpr const char* KEY_RADIUS     = "plugin:scrolloverview:dock:corner_radius";
constexpr const char* KEY_BG_COLOR   = "plugin:scrolloverview:dock:background_color";
constexpr const char* KEY_BG_OPACITY = "plugin:scrolloverview:dock:background_opacity";
constexpr const char* KEY_BLUR_SIZE   = "plugin:scrolloverview:dock:blur_size";
constexpr const char* KEY_BLUR_PASSES = "plugin:scrolloverview:dock:blur_passes";
constexpr const char* KEY_BLUR_BRIGHT = "plugin:scrolloverview:dock:blur_brightness";
constexpr const char* KEY_BLUR_NOISE  = "plugin:scrolloverview:dock:blur_noise";
constexpr const char* KEY_BLUR_CONTR  = "plugin:scrolloverview:dock:blur_contrast";
constexpr const char* KEY_BLUR_VIBR   = "plugin:scrolloverview:dock:blur_vibrancy";
constexpr const char* KEY_MINIMIZE_MS = "plugin:scrolloverview:dock:minimize_ms";

// X30, all four read off the reference: `autohide` true / `dock-fixed` false,
// `require-pressure-to-show` true at `pressure-threshold` 100.0, `show-delay`
// 0.25, `hide-delay` 0.20, `animation-time` 0.20.
constexpr const char* KEY_AUTOHIDE     = "plugin:scrolloverview:dock:autohide";
constexpr const char* KEY_PRESSURE     = "plugin:scrolloverview:dock:pressure_threshold";
constexpr const char* KEY_SHOW_DELAY   = "plugin:scrolloverview:dock:show_delay_ms";
constexpr const char* KEY_HIDE_DELAY   = "plugin:scrolloverview:dock:hide_delay_ms";
constexpr const char* KEY_AUTOHIDE_MS  = "plugin:scrolloverview:dock:autohide_ms";

// X31, one key per reference setting: `show-running`, the two that gate the
// badge (`show-icons-notifications-counter` AND `show-icons-emblems` -- D2D
// needs both, the emblem switch is what builds the UnityIndicator at all),
// `dance-urgent-applications` and `show-dock-urgent-notify`. The dot's size and
// colour are keys too because `custom-theme-customize-running-dots` is FALSE in
// the reference, which means "take the theme's numbers" -- so the theme's
// numbers are the defaults and the key is where a different theme would land.
constexpr const char* KEY_SHOW_RUNNING  = "plugin:scrolloverview:dock:running_indicator";
constexpr const char* KEY_DOT_COLOR     = "plugin:scrolloverview:dock:indicator_color";
constexpr const char* KEY_DOT_SIZE      = "plugin:scrolloverview:dock:indicator_size";
constexpr const char* KEY_BADGE         = "plugin:scrolloverview:dock:notification_counter";
constexpr const char* KEY_EMBLEMS       = "plugin:scrolloverview:dock:emblems";
constexpr const char* KEY_DANCE_URGENT  = "plugin:scrolloverview:dock:dance_urgent";
constexpr const char* KEY_URGENT_NOTIFY = "plugin:scrolloverview:dock:urgent_notify";

// X32, one key per reference setting: `show-favorites`, `show-show-apps-button`,
// `show-apps-at-top` and `show-apps-always-in-the-edge`. The last two are a PAIR
// and the reference sets them false/true, which on a bottom dock puts the button
// at the right-hand edge, past everything else.
constexpr const char* KEY_SHOW_FAVORITES = "plugin:scrolloverview:dock:show_favorites";
constexpr const char* KEY_SHOW_APPS      = "plugin:scrolloverview:dock:show_apps_button";
constexpr const char* KEY_SHOW_APPS_TOP  = "plugin:scrolloverview:dock:show_apps_at_top";
constexpr const char* KEY_SHOW_APPS_EDGE = "plugin:scrolloverview:dock:show_apps_always_in_the_edge";

// GNOME's own Show Applications artwork. A key rather than a constant because it
// is the one part of the button a theme changes.
constexpr const char* KEY_SHOW_APPS_ICON = "plugin:scrolloverview:dock:show_apps_icon";

// X33. Scroll, middle-click, and the workspace scoping X31 left alone.
constexpr const char* KEY_SCROLL_ACTION = "plugin:scrolloverview:dock:scroll_action";
constexpr const char* KEY_MIDDLE_CLICK  = "plugin:scrolloverview:dock:middle_click_action";
constexpr const char* KEY_SHIFT_MIDDLE  = "plugin:scrolloverview:dock:shift_middle_click_action";
constexpr const char* KEY_ISOLATE_WS    = "plugin:scrolloverview:dock:isolate_workspaces";
constexpr const char* KEY_ISOLATE_LOCATIONS = "plugin:scrolloverview:dock:isolate_locations";
constexpr const char* KEY_AGNOSTIC_URG  = "plugin:scrolloverview:dock:workspace_agnostic_urgent";

// X34, one key per reference setting: `hot-keys`, `hotkeys-overlay`,
// `hotkeys-show-dock`, `shortcut-timeout` 2.0. The ACCELERATORS themselves are
// deliberately not keys here -- the reference stores `<Super>1`..`<Super>0` in
// gsettings because GNOME's `Main.wm.addKeybinding` reads them from there, and
// under Hyprland the config's own `bind` lines ARE that store. A second copy
// inside the plugin could only disagree with the one the compositor obeys.
constexpr const char* KEY_HOT_KEYS       = "plugin:scrolloverview:dock:hot_keys";
constexpr const char* KEY_HOTKEY_OVERLAY = "plugin:scrolloverview:dock:hotkeys_overlay";
constexpr const char* KEY_HOTKEY_DOCK    = "plugin:scrolloverview:dock:hotkeys_show_dock";
constexpr const char* KEY_SHORTCUT_SECS  = "plugin:scrolloverview:dock:shortcut_timeout";

// `const NUM_HOTKEYS = 10` -- the reference binds ten keys and numbers ten
// icons, and the eleventh icon onwards gets neither.
constexpr int NUM_HOTKEYS = 10;

// `updateNumberOverlay`: `font-size: max(12, 0.3 * natWidth)` logical px against
// the icon, and a box `1.2` times that, square. `border-radius: iconSize` is far
// past half the box, and CSS clamps a radius to half -- so the shape is a circle
// and half the box is the number that stays one at any icon size.
constexpr float NUMBER_FONT_MIN   = 12.F;
constexpr float NUMBER_FONT_RATIO = 0.3F;
constexpr float NUMBER_BOX_RATIO  = 1.2F;

// `.number-overlay`: `color: white; background-color: rgba(0, 0, 0, 0.8)`.
constexpr float NUMBER_BG_ALPHA = 0.8F;

// The reference keeps one timeout id per dock and restarts it on every press
// (`_showOverlay`: "Restart the counting if the shortcut is pressed again"). A
// DEADLINE is the same thing with no timer to leak: restarting is one
// assignment and asking whether the overlay is up is one comparison. ONE
// deadline rather than one per monitor because there is one keyboard --
// `_showOverlay` loops over `allDocks` and hands every dock the same timeout.
Time::steady_tp g_overlayUntil = Time::steadyNow();

bool overlayUp() {
    return Config::getValue<bool>(KEY_HOT_KEYS) && Config::getValue<bool>(KEY_HOTKEY_OVERLAY) && Time::steadyNow() < g_overlayUntil;
}

// X34. Reveal the dock while the overlay is up, on the same `want` the pressure
// barrier feeds. The reference calls `dock._show()` and then leans on the
// timeout's `_updateDashVisibility()` to put it back -- so the hold ENDS with
// the overlay rather than being undone separately, which is what a deadline
// read once per frame gives for free.
//
// Gated on `hotkeys-show-dock`, and the reference gates it again on the dock
// being hideable at all (`_intellihideIsEnabled || _autohideIsEnabled`) -- with
// autohide off the pill is already up and there is nothing to reveal.
bool overlayHoldsDock() {
    return Config::getValue<bool>(KEY_HOT_KEYS) && Config::getValue<bool>(KEY_HOTKEY_DOCK) && Config::getValue<bool>(KEY_AUTOHIDE) && Time::steadyNow() < g_overlayUntil;
}

// The reference's own two numbers, hardcoded because the reference hardcodes
// them: 250ms of dead time between wheel events, so one flick is one step rather
// than ten (`_optionalScrollCycleWindowsDeadTimeId`), and 3000ms of memory for
// the cycle's window list, because activating a window reorders the stack the
// list came from (`MEMORY_TIME` in `_cycleThroughWindows`).
constexpr float SCROLL_DEAD_MS  = 250.F;
constexpr float CYCLE_MEMORY_MS = 3000.F;

// X24, the last piece: the shrink INTO the dock.
//
// The window is stashed IMMEDIATELY and this then draws it, live, from its last
// on-screen box into the slot it is going to occupy. Stashing first is what
// keeps the compositor from drawing the real window alongside the proxy for the
// length of the flight -- the double image the overview spec forbids -- and it
// costs nothing, because a stashed window stays mapped and X25 already renders
// stashed windows through renderOverviewWindow. So this is the same render path
// as the previews and the overview's own tiles, not a second one.
// A flight's KIND, frozen at creation (Z18: re-deriving it per frame flipped a
// flight between proxy and drive when the overview closed mid-flight):
//   MinimizeProxy  window -> icon, drawn as a proxy surface
//   RestoreProxy   icon -> window, proxy (overview path: the real window is hidden)
//   RestoreDriven  icon -> window, the REAL window driven natively (desktop path;
//                  Z17: no proxy, so no proxy/real hand-off seam)
enum class EFlightKind { MinimizeProxy, RestoreProxy, RestoreDriven };

// A flight is Flying until it reaches its target, then Landing for up to
// LAND_HOLD_FRAMES held frames (Z4: restore-then-erase in one frame left a frame
// with neither proxy nor real window on screen; the proxy holds its landing box
// while the real window works its way back through moveWindowToWorkspace +
// retile + damage, and one held frame still dipped to 7% of the window's area at
// the z4 gate's frame 232). Erased from g_flights = gone.
enum class EFlightPhase { Flying, Landing };
inline constexpr int LAND_HOLD_FRAMES = 2;

struct SFlight {
    PHLWINDOWREF    window;
    CBox            from;      // the WINDOW's box, monitor-local RENDER px
    EFlightKind     kind = EFlightKind::MinimizeProxy;
    Time::steady_tp startedAt;
    // Z5. A click mid-flight REVERSES the motion from wherever the proxy
    // visually is -- restarting from the icon read as a teleport under a spam
    // of clicks. `start` overrides the motion's origin (empty = the default
    // end), `alphaFrom` seeds the fade so the alpha is continuous too, and
    // `lastDrawn`/`lastAlpha` are what the NEXT reversal starts from
    // (lastAlpha < 0 = this flight has not drawn a frame yet).
    CBox  start;
    float alphaFrom = -1.F;
    CBox  lastDrawn;
    float lastAlpha = -1.F;
    // Landing bridge (see EFlightPhase). landHeldFrames counts the held frames
    // once Landing; it stays 0 the whole time the flight is Flying.
    EFlightPhase phase          = EFlightPhase::Flying;
    int          landHeldFrames = 0;

    bool isRestore() const { return kind != EFlightKind::MinimizeProxy; }
    bool isDriven() const { return kind == EFlightKind::RestoreDriven; }
    bool isLanding() const { return phase == EFlightPhase::Landing; }
};

// Z13. The tile a window occupied when it was minimized WITH THE OVERVIEW
// OPEN. Grid slots are recomputed when the window rejoins the workspace, so
// aiming a restore at the scaled desktop box lands wrong and the tile then
// snaps into the grid ("teleports among the distribution"). The slot it HAD
// is the best predictor: same window set, same slot. Used once, then dropped.
std::vector<std::pair<PHLWINDOWREF, CBox>> g_minimizeTiles;

void rememberMinimizeTile(const PHLWINDOW& window, const CBox& tile) {
    std::erase_if(g_minimizeTiles, [&](const auto& e) { return !e.first.lock() || e.first.lock() == window; });
    g_minimizeTiles.emplace_back(window, tile);
}

CBox takeMinimizeTile(const PHLWINDOW& window) {
    const auto IT = std::ranges::find_if(g_minimizeTiles, [&](const auto& e) { return e.first.lock() == window; });
    if (IT == g_minimizeTiles.end())
        return {};
    const CBox TILE = IT->second;
    g_minimizeTiles.erase(IT);
    return TILE;
}

// Y4/Y5. ONE FLIGHT PER WINDOW, replacing the single optional. Y4 makes
// "minimize the whole app" the DEFAULT click, so the old one-at-a-time rule --
// which was a documented ponytail shortcut while only shift could reach it --
// would now teleport two of a three-window app on the user's ordinary gesture.
std::vector<SFlight> g_flights;

// Z4. Everything the compositor wants to ANIMATE about a just-restored window
// -- geometry easing from its stash box, the MOVE_TO_WORKSPACE fade -- must be
// warped to its goal: the flight already was the animation, and each of these
// measurably painted its own artifact frame (a transient small box; a
// full-size window at 7% alpha).
void warpRestoredWindowAnims(const PHLWINDOW& window) {
    if (!window)
        return;
    window->m_realPosition->warp();
    window->m_realSize->warp();
    for (uint8_t i = 0; i < Desktop::View::WINDOW_ALPHA_LAST; ++i)
        window->alpha()[i]->warp();
}

// A minimize is an exit, so it accelerates. This used to be a cubic mirror --
// the right SHAPE but not the house curve; houseEase evaluates the registered
// bezier itself, so the dock and the overview are exactly the same motion.
float exitEase(float t) {
    return houseEase(false, t);
}

// Y5. GNOME's MINIMIZE_WINDOW_ANIMATION_MODE is Clutter's EASE_OUT_EXPO, which
// is 1 - 2^(-10t) snapped to exactly 1 at the end. Extracted from the host's
// windowManager.js, not recalled -- see spec 13.14's reference-discipline note.
//
// This is why Y5 can be BOTH "GNOME's 400ms" and tighter than the 220ms bezier
// X54 asked to shorten: expo is ~87% done at t=0.3 and ~97% at t=0.5, so the
// window is visually in the icon long before the clock runs out.
float easeOutExpo(float t) {
    return t >= 1.F ? 1.F : 1.F - std::pow(2.F, -10.F * t);
}

// Y6. GNOME's launch feedback, from iconGrid.js `zoomOutActorAtPos`: a CLONE of
// the icon scales to 3x about its own centre (pivot 0.5, 0.5) while easing
// opacity to nothing, CLAMPED so the blow-up cannot leave the monitor. The real
// icon underneath is untouched, which is why this is a separate list and not a
// transform on the item.
constexpr float LAUNCH_ZOOM_SCALE = 3.F;   // APPICON_ANIMATION_OUT_SCALE
constexpr float LAUNCH_ZOOM_MS    = 250.F; // APPICON_ANIMATION_OUT_TIME

struct SLaunchZoom {
    std::string     icon;
    CBox            from;
    Time::steady_tp startedAt;
};

std::vector<SLaunchZoom> g_launchZooms;

// `Clutter.AnimationMode.EASE_OUT_QUAD`.
float easeOutQuad(float t) {
    return 1.F - (1.F - t) * (1.F - t);
}

// Y7. The user's own threshold: "within a threshold, say, bottom 30% of the
// screen". Zero at the top of that band and full at the pill, CONTINUOUS in
// between -- a glow that switches on at the boundary is not "correlated to the
// distance", which is what was asked for.
constexpr float DRAG_GLOW_BAND  = 0.30F;
constexpr float DRAG_GLOW_PX    = 18.F; // how far the halo reaches past the pill
constexpr float DRAG_GLOW_ALPHA = 0.55F;

bool g_windowDragActive = false;

// Y8. macOS hops the icon a thing LANDS in -- once, not a decaying train, and
// on arrival rather than on release. Up decelerates and down accelerates, which
// is both the house rule and what falling actually does.
constexpr float BOUNCE_MS       = 420.F;
constexpr float BOUNCE_HEIGHT   = 0.34F; // of one icon height
constexpr float BOUNCE_UP_SHARE = 0.42F; // the hop is quicker up than down

struct SBounce {
    std::string     wmClass;
    Time::steady_tp startedAt;
};

std::vector<SBounce> g_bounces;

float bounceCurve(float t) {
    if (t <= 0.F || t >= 1.F)
        return 0.F;

    return t < BOUNCE_UP_SHARE ? houseEase(true, t / BOUNCE_UP_SHARE) : 1.F - houseEase(false, (t - BOUNCE_UP_SHARE) / (1.F - BOUNCE_UP_SHARE));
}

float flightProgress(const SFlight& flight) {
    const int DURATION = Config::getValue<int>(KEY_MINIMIZE_MS);
    if (DURATION <= 0)
        return 1.F;

    return std::clamp(ScrollOverview::Config::animElapsedMs(flight.startedAt) / sc<float>(DURATION), 0.F, 1.F);
}

CBox lerpBox(const CBox& a, const CBox& b, float t) {
    return CBox{a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.w + (b.w - a.w) * t, a.h + (b.h - a.h) * t};
}

struct SMetrics {
    float icon   = 0.F;
    float width  = 0.F;
    float height = 0.F;
};

// Pure, so the proportions can be asserted without a compositor. `icon-size-fixed`
// is false in the reference, which is what licenses the shrink: over the
// height-fraction cap D2D makes the icons smaller rather than overflowing.
//
// `units` is the width of every slot expressed in icon-widths: 1.0 per app icon,
// the clamped aspect ratio per preview. With no previews it equals `slots` and
// this is byte-for-byte the X27 formula.
SMetrics metrics(size_t slots, float units, float iconMax, float maxWidth) {
    if (slots == 0)
        return {};

    const float N      = sc<float>(slots);
    const float CHROME = 2.F * CONTAINER_PAD_X + 2.F * ITEM_MARGIN_X * N;
    const float AVAIL  = maxWidth - CHROME;

    SMetrics out;
    out.icon   = std::max(8.F, std::min(iconMax, AVAIL / std::max(units, 0.01F)));
    out.width  = CHROME + out.icon * units;
    out.height = ITEM_PAD_TOP + out.icon + ITEM_PAD_BOTTOM;
    return out;
}

// -------------------------------------------------------------- X32 pins --

// Favourites are a LIST OF DESKTOP IDS, the same unit GNOME's `favorite-apps`
// key uses. A plain file, because a plugin cannot write a Hyprland config key
// back out and this is user data rather than a tunable.
std::filesystem::path favoritesPath() {
    if (const char* STATE = std::getenv("XDG_STATE_HOME"); STATE && *STATE)
        return std::filesystem::path{STATE} / "scrolloverview" / "favorites";

    if (const char* HOME = std::getenv("HOME"); HOME && *HOME)
        return std::filesystem::path{HOME} / ".local" / "state" / "scrolloverview" / "favorites";

    return {};
}

// Seeds an EMPTY store only, and only with neutral entries every desktop is
// likely to have -- an id that no desktop entry claims is dropped at layout
// time, not here. Real dock contents are whatever the user pins; the store
// under ~/.local/state/scrolloverview/favorites wins from the first write on.
constexpr std::array<const char*, 3> DEFAULT_FAVORITES = {
    "org.gnome.Nautilus",
    "org.gnome.TextEditor",
    "org.gnome.Ptyxis",
};

std::vector<std::string>& favorites() {
    static std::vector<std::string> cache;
    static bool                     loaded = false;

    if (!loaded) {
        loaded = true;

        // A MISSING file seeds; an EMPTY one does not. Unpinning the last
        // favourite is a thing the user did on purpose, and re-seeding it on the
        // next start would undo them silently.
        if (std::error_code ec; !std::filesystem::exists(favoritesPath(), ec)) {
            cache.assign(DEFAULT_FAVORITES.begin(), DEFAULT_FAVORITES.end());
            return cache;
        }

        std::ifstream file(favoritesPath());
        std::string   line;
        while (std::getline(file, line)) {
            while (!line.empty() && (line.back() == '\r' || line.back() == ' ' || line.back() == '\t'))
                line.pop_back();
            if (!line.empty())
                cache.emplace_back(line);
        }
    }

    return cache;
}

void writeFavorites() {
    const auto PATH = favoritesPath();
    if (PATH.empty())
        return;

    std::error_code ec;
    std::filesystem::create_directories(PATH.parent_path(), ec);

    std::ofstream out(PATH, std::ios::trunc);
    for (const auto& F : favorites())
        out << F << "\n";
}

void toggleFavorite(const std::string& id) {
    if (id.empty())
        return;

    auto& FAV = favorites();
    if (const auto IT = std::ranges::find(FAV, id); IT != FAV.end())
        FAV.erase(IT);
    else
        FAV.emplace_back(id);

    writeFavorites();
}

// X33. The reference's `getInterestingWindows()`: the one filter every list the
// dock builds runs through, so the icons, the dot, the menu, the cycle and the
// quit all agree on which windows exist.
//
// `isolate-workspaces` is FALSE in the reference, so by default this is every
// mapped window and the dock stays workspace-agnostic exactly as X27 left it.
// Turned on, it is the CURRENT workspace only -- the focused monitor's, because
// `isolate-monitors` is false and the reference then asks the global workspace
// manager, not a per-monitor one.
//
// Two exemptions, both load-bearing:
//   * `workspace-agnostic-urgent-windows` (TRUE) keeps an urgent window listed
//     wherever it is, which is the whole point of the key: an app demanding
//     attention on another desktop must still be reachable from the dock.
//   * a MINIMIZED window is always interesting. Ours are stashed on a special
//     workspace that is never any monitor's active one, so isolation would hide
//     every minimized window and X24's click-to-restore would have nothing left
//     to restore. Its real home is the workspace it will come back to.
bool interesting(const PHLWINDOW& window) {
    if (!window || !window->m_isMapped)
        return false;

    if (!Config::getValue<bool>(KEY_ISOLATE_WS))
        return true;

    if (Minimize::isMinimized(window))
        return true;

    if (window->m_isUrgent && Config::getValue<bool>(KEY_AGNOSTIC_URG))
        return true;

    const auto MONITOR = Desktop::focusState()->monitor();
    return MONITOR && window->m_workspace == MONITOR->m_activeWorkspace;
}

// X27 showed what is RUNNING and nothing else. X32 keeps that list and puts the
// FAVOURITES in front of it: the compositor's own window order, which is stable
// across frames -- an MRU order here would make the dock reshuffle on every
// focus.
std::vector<std::string> runningClasses() {
    std::vector<std::string>        out;
    std::unordered_set<std::string> seen;

    for (const auto& windowRef : Desktop::windowState()->windows()) {
        const auto& WINDOW = windowRef;
        if (!interesting(WINDOW) || WINDOW->m_class.empty())
            continue;

        if (seen.insert(WINDOW->m_class).second)
            out.emplace_back(WINDOW->m_class);
    }

    return out;
}

// X32. What the pill lists, in order, with no geometry on it yet: every
// favourite first -- running or not -- then everything running that no favourite
// already covers.
//
// The two lists are keyed on DIFFERENT things, which is the whole difficulty. A
// favourite is a desktop id and owns no window until it is launched; a running
// app is a window class and may have no desktop entry at all. `idForClass` is
// the only bridge, so it is asked once per running class and the answer decides
// which list the class belongs to.
std::vector<SItem> dockItems() {
    const auto RUNNING = runningClasses();

    std::vector<std::string> runningIds;
    runningIds.reserve(RUNNING.size());
    for (const auto& CLASS : RUNNING)
        runningIds.emplace_back(AppSearch::idForClass(CLASS));

    std::vector<SItem> out;
    std::unordered_set<size_t> claimed;

    if (Config::getValue<bool>(KEY_SHOW_FAVORITES)) {
        for (const auto& ID : favorites()) {
            const auto* ENTRY = AppSearch::entryForId(ID);
            // A favourite nothing on this machine provides is dropped rather
            // than drawn as a blank slot: the seed is the user's HOST list and
            // the test VM has a fraction of it installed.
            if (!ENTRY)
                continue;

            SItem item;
            item.desktopId = ID;
            item.icon      = ENTRY->icon;
            item.favorite  = true;

            // First running class that resolves to this id owns the slot, so a
            // pinned app that IS running is one icon, not two.
            for (size_t i = 0; i < RUNNING.size(); ++i) {
                if (runningIds[i] != ID || claimed.contains(i))
                    continue;

                claimed.insert(i);
                item.wmClass = RUNNING[i];
                item.running = true;
                break;
            }

            out.emplace_back(std::move(item));
        }
    }

    for (size_t i = 0; i < RUNNING.size(); ++i) {
        if (claimed.contains(i))
            continue;

        out.emplace_back(SItem{
            .wmClass   = RUNNING[i],
            .icon      = AppSearch::iconForClass(RUNNING[i]),
            .desktopId = runningIds[i],
            .running   = true,
        });
    }

    // X35. Locations come after every app, which is where `Locations.getApps()`
    // puts them once `shellAppCompare` has sorted the running ones to the front.
    //
    // `isolate_locations` TRUE is what makes this a plain append: a location's
    // running state is ITS OWN, so it is asked of the file manager's open
    // windows rather than inherited from whether Nautilus happens to be up. With
    // the key off, a location is drawn but never marked running -- the reference
    // reaches for the file manager's own AppIcon there, and this dock has no
    // second icon to hand the state to.
    const bool ISOLATE = Config::getValue<bool>(KEY_ISOLATE_LOCATIONS);
    for (const auto& LOCATION : Locations::items()) {
        out.emplace_back(SItem{
            .icon         = LOCATION.icon,
            .running      = ISOLATE && Locations::openWindows(LOCATION.uri),
            .uri          = LOCATION.uri,
            .locationName = LOCATION.name,
            .mount        = LOCATION.mount,
            .canEject     = LOCATION.canEject,
            .mounted      = LOCATION.mounted,
            .trashEmpty   = LOCATION.empty,
        });
    }

    return out;
}

std::vector<PHLWINDOW> previewWindows() {
    auto out = Minimize::minimized();
    std::erase_if(out, [](const auto& window) { return !window || !window->m_isMapped || !window->wlSurface() || !window->wlSurface()->resource(); });
    return out;
}

float previewAspect(const PHLWINDOW& window) {
    const auto SIZE = window->m_realSize->value();
    if (SIZE.x < 1.0 || SIZE.y < 1.0)
        return 1.F;

    return std::clamp(sc<float>(SIZE.x / SIZE.y), PREVIEW_MIN_ASPECT, PREVIEW_MAX_ASPECT);
}

CHyprColor background() {
    // D2D `transparency-mode` FIXED with `custom-background-color`: the hue and
    // the alpha are two independent settings, so the key's own alpha is ignored.
    const auto     OPACITY = std::clamp(Config::getValue<float>(KEY_BG_OPACITY), 0.F, 1.F);
    const uint32_t ARGB    = Config::getValue<uint32_t>(KEY_BG_COLOR);

    return CHyprColor{sc<float>((ARGB >> 16) & 0xFF) / 255.F, sc<float>((ARGB >> 8) & 0xFF) / 255.F, sc<float>(ARGB & 0xFF) / 255.F, OPACITY};
}

// X25. A minimized window lives on a special workspace nobody shows, so every
// one of the compositor's "is this worth drawing?" answers is no. The overview
// solves the same problem by saving the old values and restoring them on close;
// here there is nothing to restore to -- while the window is minimized, VISIBLE
// is its state -- so this just asserts it each frame.
void forcePreviewVisible(const PHLWINDOW& window) {
    window->m_hidden = false;

    // The one that actually froze the preview: a window on a hidden workspace
    // gets the xdg_toplevel `suspended` state, and a client that honours it
    // stops drawing at all -- measured 0 frame callbacks and 0 commits over 5s
    // minimized against 52/52 visible, which no amount of acking frames on our
    // side can fix. GlobalWindowController re-asserts suspension on every
    // visibility change, so this is re-checked each frame rather than set once.
    if (window->m_suspended)
        window->setSuspended(false);
    window->alpha(Desktop::View::WINDOW_ALPHA_FULLSCREEN)->setValueAndWarp(1.F);

    if (const auto WORKSPACE = window->m_workspace; WORKSPACE && WORKSPACE->m_alpha) {
        WORKSPACE->m_alpha->setValueAndWarp(1.F);
        *WORKSPACE->m_alpha = 1.F;
    }

    window->wlSurface()->resource()->breadthfirst(
        [](SP<CWLSurfaceResource> surface, const Vector2D&, void*) {
            if (const auto HLSURFACE = Desktop::View::CWLSurface::fromResource(surface); HLSURFACE)
                HLSURFACE->m_visibleRegion = {};
        },
        nullptr);
}

// The whole difference between a live preview and a stale one. A client draws
// the next frame when the last one is acked; nobody acks a window on a hidden
// workspace, so without this the preview freezes on whatever it happened to
// have committed when it was minimized -- which the spec calls a defect.
void presentPreview(const PHLWINDOW& window, PHLMONITOR monitor, const Time::steady_tp& now) {
    std::pair<PHLMONITOR, Time::steady_tp> data = {monitor, now};

    window->wlSurface()->resource()->breadthfirst(
        [](SP<CWLSurfaceResource> surface, const Vector2D&, void* data) {
            const auto [MONITOR, NOW] = *sc<std::pair<PHLMONITOR, Time::steady_tp>*>(data);
            surface->presentFeedback(NOW, MONITOR, false);
        },
        &data);
}

std::unordered_map<MONITORID, std::string> g_signatures;

// X30. AUTOHIDE. The pill is away by default (`autohide` true, `dock-fixed`
// false) and is revealed by pushing the pointer into the bottom edge until the
// barrier's pressure passes `pressure-threshold`. Once up it stays up while the
// pointer is on it, and the overview pins it out the way clause 6 requires.
//
// `intellihide` is FALSE in the reference and its mode is inert while off, so
// there is deliberately no window-overlap hiding here -- that is the setting
// being honoured, not a gap.
//
// `autohide-in-fullscreen` is TRUE, and that is why there is no fullscreen
// branch either: the barrier keeps working under a fullscreen window instead of
// the dock locking itself away, and the pill is drawn at RENDER_POST_WINDOWS so
// a revealed dock lands over the fullscreen window. The behaviour is the
// absence of a special case; the test is what proves it.
struct SReveal {
    bool            shown        = false;
    Time::steady_tp changedAt    = Time::steadyNow(); // start of the slide toward `shown`
    bool            pending      = false;             // a flip is waiting out its delay
    Time::steady_tp pendingSince = Time::steadyNow();
    float           pressure     = 0.F;               // px pushed into the bottom edge
    // X75. The hidden fraction AT THE MOMENT OF THE FLIP. The slide used to be
    // computed from elapsed time alone, so reversing mid-slide restarted the
    // curve at the far end and the pill JUMPED there before travelling back.
    // dash-to-dock has no such seam: `_animateIn`/`_animateOut` are Clutter
    // eases on the slider, and an ease always departs from wherever the value
    // currently is.
    float           from         = 1.F;
};

std::unordered_map<MONITORID, SReveal> g_reveal;

// The barrier is the monitor's last row, and the cursor is clamped there -- but
// a clamp can leave it a pixel short, so the band is not exactly one row.
constexpr float EDGE_BAND = 2.F;

// The band that opens the dock on POSITION alone, deliberately a little wider
// than EDGE_BAND -- "on or near the bottom edge".
constexpr float REVEAL_BAND = 4.F;

float elapsedMs(const Time::steady_tp& since) {
    // Every timed thing in the dock already funnels through here -- the hover
    // panel, the tooltip fade, the bounce, the launch zoom, the autohide slide
    // and the hotkey overlay -- so routing it through the global scale is the
    // whole of the slider on this side. Constants keep their real values.
    return ScrollOverview::Config::animElapsedMs(since);
}

// ---- X31 -------------------------------------------------------------------

// `workspace-agnostic-urgent-windows` is TRUE, so this asks about the APP and
// never about a workspace: any mapped window of the class, anywhere, counts.
// The LauncherEntry half is the same question asked over D-Bus -- an app can
// demand attention without owning an urgent surface (`urgent` in the protocol),
// and the reference reads both.
bool classUrgent(const std::string& wmClass) {
    for (const auto& WINDOW : Desktop::windowState()->windows()) {
        if (WINDOW && WINDOW->m_isMapped && WINDOW->m_isUrgent && WINDOW->m_class == wmClass)
            return true;
    }

    return LauncherEntry::state(AppSearch::idForClass(wmClass)).urgent;
}

// `application-counter-overrides-notifications` is TRUE, so a LauncherEntry
// count wins outright whenever the app publishes one -- which under Hyprland is
// the whole answer, because the other half of the reference's sum is GNOME
// Shell's message tray and there is no tray here to read. Named in
// RICE_PROGRESS.md as an open decision, not silently folded to zero.
long long badgeCount(const std::string& wmClass) {
    if (!Config::getValue<bool>(KEY_BADGE) || !Config::getValue<bool>(KEY_EMBLEMS))
        return 0;

    const auto STATE = LauncherEntry::state(AppSearch::idForClass(wmClass));
    return STATE.countVisible ? std::max<long long>(0, STATE.count) : 0;
}

bool anyUrgent(const std::vector<SItem>& items) {
    // X32: a pinned app with no window has no class, and classUrgent keyed on ""
    // would ask LauncherEntry about the empty id once per item per frame.
    // X35: and a location has no class either, nor any way to go urgent.
    return std::ranges::any_of(items, [](const SItem& item) { return item.running && item.uri.empty() && classUrgent(item.wmClass); });
}

// Radians, because CBox::rot is; the reference's degrees are converted at the
// last moment so the numbers above stay the ones that were read off it. The
// epoch is shared and set once, which is what keeps two urgent icons in phase.
float wiggleRadians() {
    static const Time::steady_tp EPOCH = Time::steadyNow();

    const float PROGRESS = std::fmod(elapsedMs(EPOCH), WIGGLE_PERIOD_MS) / WIGGLE_PERIOD_MS;
    if (PROGRESS >= WIGGLE_FRACTION)
        return 0.F;

    const float DEGREES = WIGGLE_DEGREES * std::sin(PROGRESS * 24.F * sc<float>(M_PI));
    return DEGREES * sc<float>(M_PI) / 180.F;
}

// ----------------------------------------------------------------------------

// X75 (user, 2026-08-06: "behave exactly like the autohide behavior in the
// dash to dock gnome extension"). dash-to-dock eases the slider with
// Clutter's EASE_OUT_QUAD in BOTH directions -- `_animateIn` and `_animateOut`
// pass the same mode -- so the hide does NOT accelerate away the way this
// rice's house exit curve does. Matching the reference means dropping the
// house asymmetry here; that is the instruction, not an oversight.
//
// Direction is no longer a parameter, because the curve no longer depends on it.
float revealEase(float t) {
    const float INV = 1.F - std::clamp(t, 0.F, 1.F);
    return 1.F - (INV * INV);
}

// 0 = fully out, 1 = fully tucked below the bottom edge.
float hiddenFraction(PHLMONITOR monitor) {
    if (!monitor)
        return 0.F;

    const auto& R  = g_reveal[monitor->m_id];
    const int   MS = std::max(1, Config::getValue<int>(KEY_AUTOHIDE_MS));
    const float E  = revealEase(std::clamp(elapsedMs(R.changedAt) / sc<float>(MS), 0.F, 1.F));

    // From wherever it WAS to wherever it is going, which is what makes a
    // reversal continuous instead of a jump to the far end.
    return R.from + ((R.shown ? 0.F : 1.F) - R.from) * E;
}

SLayout baseLayout(PHLMONITOR monitor); // defined below; slidPill needs the resting box

// How far down the pill currently sits, mid-slide included. Shared with
// layout() below so the HIT TEST and the RENDER can never disagree about where
// the pill is -- which is the whole bug X77 fixes.
double slideOffsetPx(PHLMONITOR monitor, double pillHeight) {
    if (!monitor)
        return 0.0;

    return std::round((pillHeight + EDGE_MARGIN * monitor->m_scale) * hiddenFraction(monitor));
}

// The pill WHERE IT IS, not where it rests. Empty once it is fully away.
CBox slidPill(PHLMONITOR monitor) {
    auto pill = baseLayout(monitor).pill;
    if (pill.empty() || hiddenFraction(monitor) >= 1.F)
        return CBox{};

    pill.y += slideOffsetPx(monitor, pill.height);
    return pill;
}

bool autohideAnimating(PHLMONITOR monitor) {
    if (!monitor)
        return false;

    const auto& R = g_reveal[monitor->m_id];
    // X54. A flight counts as animating: the window is mid-air toward the icon
    // and nothing else on an idle desktop would ask for the frames it needs.
    return R.pending || !g_flights.empty() || elapsedMs(R.changedAt) < sc<float>(std::max(1, Config::getValue<int>(KEY_AUTOHIDE_MS)));
}

SLayout baseLayout(PHLMONITOR monitor) {
    SLayout out;

    if (!monitor || !Config::getValue<bool>(KEY_ENABLED) || monitor->m_size.x < 1 || monitor->m_size.y < 1)
        return out;

    auto items = dockItems();

    // X46. A minimized window used to be appended to the pill as a preview
    // slot of its own. It is not any more: the pill's cells, centres and width
    // must not move when something is minimized, because the user asked for the
    // window to go INTO its icon rather than to sprout a second entry. Live
    // previews still exist -- X47 raises them on HOVER instead, which is also
    // where the SPreview machinery below now gets its contents.
    const std::vector<PHLWINDOW> MINIMIZED;

    // X32. The button is a slot of its own, so it widens the pill and competes
    // for icon size with everything else -- and it is the ONE thing that can put
    // a pill on screen by itself, on a desktop with nothing running and nothing
    // pinned. That is the reference's behaviour: `show-show-apps-button` does
    // not go away when the dash is empty.
    const bool SHOWAPPS = Config::getValue<bool>(KEY_SHOW_APPS);
    if (items.empty() && MINIMIZED.empty() && !SHOWAPPS)
        return out;

    std::vector<float> aspects;
    aspects.reserve(MINIMIZED.size());
    float units = sc<float>(items.size()) + (SHOWAPPS ? 1.F : 0.F);
    for (const auto& WINDOW : MINIMIZED) {
        aspects.emplace_back(previewAspect(WINDOW));
        units += aspects.back();
    }

    const float SCALE    = std::max(monitor->m_scale, 0.01F);
    const float ICONMAX  = sc<float>(std::clamp(Config::getValue<int>(KEY_ICON_SIZE), 8, 512));
    const float FRACTION = std::clamp(Config::getValue<float>(KEY_FRACTION), 0.05F, 1.F);
    const auto  M        = metrics(items.size() + MINIMIZED.size() + (SHOWAPPS ? 1 : 0), units, ICONMAX, FRACTION * sc<float>(monitor->m_size.x));

    // `extend-height` false and `always-center-icons` false: a floating pill
    // sized to its contents, centred on the monitor, clear of the bottom edge.
    const float XL = (sc<float>(monitor->m_size.x) - M.width) / 2.F;
    const float YL = sc<float>(monitor->m_size.y) - EDGE_MARGIN - M.height;

    out.pill = CBox{XL * SCALE, YL * SCALE, M.width * SCALE, M.height * SCALE};
    out.pill.round();
    out.rounding = std::max(0, sc<int>(std::round(sc<float>(Config::getValue<int>(KEY_RADIUS)) * SCALE)));

    float cursor = XL + CONTAINER_PAD_X + ITEM_MARGIN_X;
    out.items = std::move(items);
    for (auto& item : out.items) {
        item.iconBox = CBox{cursor * SCALE, (YL + ITEM_PAD_TOP) * SCALE, M.icon * SCALE, M.icon * SCALE};
        item.iconBox.round();

        cursor += M.icon + 2.F * ITEM_MARGIN_X;
    }

    // X25 previews sit to the RIGHT of the running icons, the end of the dock a
    // minimized window goes to on the reference desktop the user works on.
    out.previews.reserve(MINIMIZED.size());
    for (size_t i = 0; i < MINIMIZED.size(); ++i) {
        const float WIDTH = M.icon * aspects[i];

        SPreview preview;
        preview.window = MINIMIZED[i];
        preview.box    = CBox{cursor * SCALE, (YL + ITEM_PAD_TOP) * SCALE, WIDTH * SCALE, M.icon * SCALE};
        preview.box.round();
        out.previews.emplace_back(std::move(preview));

        cursor += WIDTH + 2.F * ITEM_MARGIN_X;
    }

    // X32 Show Applications. `show-apps-at-top` FALSE puts it at the far end of
    // a bottom dock, and `show-apps-always-in-the-edge` TRUE is what keeps it
    // there rather than letting it float in with the apps -- so it lands after
    // the previews, which is the last slot the cursor has reached.
    //
    // `at_top` true is honoured by laying it out FIRST instead. The pair is the
    // reference's, and one without the other would be half a setting.
    if (SHOWAPPS) {
        const bool  FIRST = Config::getValue<bool>(KEY_SHOW_APPS_TOP) || !Config::getValue<bool>(KEY_SHOW_APPS_EDGE);
        const float X     = FIRST ? XL + CONTAINER_PAD_X + ITEM_MARGIN_X : cursor;

        out.showApps = CBox{X * SCALE, (YL + ITEM_PAD_TOP) * SCALE, M.icon * SCALE, M.icon * SCALE};
        out.showApps.round();

        // Laid out first: everything else slides one slot right, rather than
        // being overdrawn by it.
        if (FIRST) {
            const double SHIFT = (M.icon + 2.F * ITEM_MARGIN_X) * SCALE;
            for (auto& item : out.items)
                item.iconBox.x += SHIFT;
            for (auto& preview : out.previews)
                preview.box.x += SHIFT;
        }
    }

    return out;
}

// X30's state machine. Runs from damageIfChanged, so it advances on every frame
// the dock asks for and on every pointer motion, which is every moment either
// timer can expire.
// Y1. Defined with the panel further down; declared here because the autohide
// has to ask the same question the render does -- a panel the pointer is inside
// must hold the dock out, exactly as an open menu already does.
bool panelHoldsDock(PHLMONITOR monitor);

void updateAutohide(PHLMONITOR monitor) {
    if (!monitor)
        return;

    auto& R = g_reveal[monitor->m_id];

    // Pinned: autohide switched off, or the overview is open over this monitor.
    // Neither waits out `show-delay` -- that delay belongs to the pressure
    // barrier, and making the overview's own dock crawl in behind it would be
    // reading the reference wrong.
    if (!Config::getValue<bool>(KEY_AUTOHIDE) || scrollOverviewForMonitor(monitor)) {
        if (!R.shown) {
            R.from      = hiddenFraction(monitor);
            R.shown     = true;
            R.changedAt = Time::steadyNow();
        }
        R.pending  = false;
        R.pressure = 0.F;
        return;
    }

    // X31 `show-dock-urgent-notify` true: an app demanding attention brings the
    // dock out on its own. It is ORed into BOTH branches below, not just the
    // hidden one -- an urgent app also has to stop the pointer leaving from
    // sliding the dock away again, or the wiggle would play to nobody.
    const bool URGENT = Config::getValue<bool>(KEY_URGENT_NOTIFY) && anyUrgent(baseLayout(monitor).items);

    bool       want      = false;
    // A reversal that catches the pill still on screen does not wait out a
    // delay; see the X77 note below.
    bool       immediate = false;
    if (R.shown) {
        // Up already: it stays up while the pointer is on it, or while its
        // right-click menu is -- the menu floats ABOVE the pill, so reaching for
        // a row takes the pointer off the pill and would otherwise slide the
        // dock out from under the menu the user is aiming at.
        // Y1. The hover preview panel holds the dock for the same reason the
        // menu does, and more sharply: the panel floats a gap ABOVE the pill, so
        // reaching into it necessarily takes the pointer off the pill. Without
        // this the dock slides out from under the previews the user is reaching
        // for, which is the second half of the reported bug.
        if (menuOpen() || panelHoldsDock(monitor))
            want = true;
        else if (CBox reach = slidPill(monitor); !reach.empty()) {
            // X77: the SLID pill, not the resting one. While it is still easing
            // out it sits BELOW its resting box, so a pointer on the part that
            // is actually on screen fell outside the resting box and read as
            // "left the dock" -- which started a hide the user never asked for.
            reach.height += EDGE_MARGIN * monitor->m_scale; // the margin under the pill still counts as on it
            want = reach.containsPoint((g_pInputManager->getMouseCoordsInternal() - monitor->m_position) * monitor->m_scale);
        }
    } else {
        // `require-pressure-to-show`, plus a POSITION test that every pointer
        // can satisfy.
        //
        // The pressure barrier alone was measured dead on this guest, and the
        // reason generalises: its feed hooks `CInputManager::onMouseMoved`,
        // which is the RELATIVE motion path, while the pointer here is a
        // `qemu-qemu-usb-tablet` -- an ABSOLUTE device. No relative event ever
        // arrives, so pressure never accumulates and the dock never comes out.
        // (An earlier test "passed" only because ydotool synthesised relative
        // deltas, which is not how the user's pointer moves.) Position is the
        // one thing every device agrees on; `show_delay_ms` is what keeps it
        // from being twitchy, and pressure still works for a relative mouse.
        const auto BOX   = monitor->logicalBox();
        const auto POINT = g_pInputManager->getMouseCoordsInternal();
        const bool ATEDGE = BOX.containsPoint(POINT) && POINT.y >= BOX.y + BOX.h - REVEAL_BAND;

        want = ATEDGE || R.pressure >= Config::getValue<float>(KEY_PRESSURE);

        // X77 (user, 2026-08-06): "if I move my cursor off it, it starts hiding
        // and I can't unhide until it's done hiding".
        //
        // `shown` flips FALSE the moment the hide begins, which switched this
        // test to the 4px screen-edge band -- while the pill was still sitting
        // on screen under the cursor, 60-odd px above that band. So coming back
        // to a dock that is visibly right there could not re-show it, and the
        // user had to wait out the slide and push into the very bottom edge
        // again. dash-to-dock has no such window: its hover lives on the actor,
        // which stays interactive for the whole slide.
        //
        // Being ON the pill that is still on screen counts, and it counts
        // IMMEDIATELY -- `show-delay` belongs to the pressure barrier, not to a
        // pointer that never really left.
        if (!want) {
            if (CBox reach = slidPill(monitor); !reach.empty()) {
                reach.height += EDGE_MARGIN * monitor->m_scale;
                if (reach.containsPoint((g_pInputManager->getMouseCoordsInternal() - monitor->m_position) * monitor->m_scale)) {
                    want      = true;
                    immediate = true;
                }
            }
        }
    }

    // X34 `hotkeys-show-dock`, ORed in beside URGENT for the same reason: it has
    // to HOLD the pill up as well as bring it out, or the pointer sitting
    // anywhere else would slide it away under the numbers the press just drew.
    // X54. A flight HOLDS the dock out, for the same reason X34's hotkey overlay
    // does: outside the overview the pill is normally hidden, so a minimize had
    // no icon to fly to -- the target lookup failed and the flight was dropped
    // on its first frame, which is why it teleported. The dock now comes out for
    // the flight and slides away after it.
    want = want || URGENT || overlayHoldsDock() || !g_flights.empty();

    if (want == R.shown) {
        R.pending = false;
        return;
    }

    if (!R.pending) {
        R.pending      = true;
        R.pendingSince = Time::steadyNow();
    }

    if (!immediate && elapsedMs(R.pendingSince) < sc<float>(std::max(0, Config::getValue<int>(want ? KEY_SHOW_DELAY : KEY_HIDE_DELAY))))
        return;

    R.from      = hiddenFraction(monitor);
    R.shown     = want;
    R.changedAt = Time::steadyNow();
    R.pending   = false;
    R.pressure  = 0.F;
}

}

SLayout layout(PHLMONITOR monitor) {
    SLayout out = baseLayout(monitor);
    if (out.pill.empty())
        return out;

    const float F = hiddenFraction(monitor);
    if (F <= 0.F)
        return out;

    // Fully away: no pill and, because everything else asks this function, no
    // hit area either -- so a click lands on the window underneath instead of
    // being swallowed by a dock that is not on screen.
    if (F >= 1.F)
        return SLayout{};

    const double DY = slideOffsetPx(monitor, out.pill.height);
    out.pill.y += DY;
    for (auto& item : out.items)
        item.iconBox.y += DY;
    for (auto& preview : out.previews)
        preview.box.y += DY;
    if (!out.showApps.empty())
        out.showApps.y += DY;

    return out;
}

namespace {

// How far the hover cell sits inside the pill, on every side. The icon is
// ITEM_PAD_TOP from the pill's top and CONTAINER_PAD_X + ITEM_MARGIN_X from its
// left, and those are equal by construction, so one number covers all four.
float hoverInset() {
    return ITEM_PAD_TOP - HOVER_PAD;
}

// The hovered cell, not the icon: GNOME's highlight is the .app-well-app box,
// which is the icon plus its padding. Symmetric now that the vertical padding is.
CBox hoverBox(const CBox& iconBox, float scale) {
    return iconBox.copy().expand(HOVER_PAD * std::max(scale, 0.01F)).round();
}

// The app's display name, over a dark rounded plate, centred on the icon and
// sitting above the pill.
// ponytail: no delay and no fade -- it appears with the highlight it belongs to.
// GNOME staggers it by ~500ms; add that if sweeping the dock reads as noisy.
// X31. The dot says RUNNING, and as of X32 that is a real distinction rather
// than a tautology: a pinned favourite with no window is an icon with no dot,
// and the dot is the only thing on the pill that tells the two apart. The
// caller gates on SItem::running.
//
// It hangs off the ICON, DOT_MARGIN_B below it -- NOT off the pill's bottom
// edge, which is where the first cut anchored it. Measured on the host: icon
// bottom 176, dot 178-182, so the dot's own bottom lands flush with the bottom
// of the hover highlight. Anchoring to the pill put it ITEM_PAD_BOTTOM -
// HOVER_PAD = 8px too low, and that gap is what read as "not 1:1".

// X87. Dock frost is always LIVE (xray=false), desktop and overview.
// One surface, so it does not reintroduce the multi-card compound bug that
// forced shared sampling for strip/search. decoration:blur:* still applies
// when the dock keys are -1 (X71). Sampling m_blurFB here was wrong for the
// desktop path (no behind-chrome pre-blur exists) and broke once the shared
// draw path was rewritten.
static void queueDockFrost(PHLMONITOR monitor, const CBox& box, int rounding, float alpha) {
    if (box.empty() || alpha <= 0.F)
        return;

    COverviewBlurPassElement::SData blur;
    blur.box            = box;
    blur.rounding       = rounding;
    blur.roundingPower  = 2.F;
    blur.alpha          = alpha;
    blur.xray           = false; // live dual-kawase of whatever is behind the pill
    // -1 on these keys means leave decoration:blur:* alone (X71).
    blur.blurSize       = Config::getValue<int>(KEY_BLUR_SIZE);
    blur.blurPasses     = Config::getValue<int>(KEY_BLUR_PASSES);
    blur.blurBrightness = Config::getValue<float>(KEY_BLUR_BRIGHT);
    blur.blurNoise      = Config::getValue<float>(KEY_BLUR_NOISE);
    blur.blurContrast   = Config::getValue<float>(KEY_BLUR_CONTR);
    blur.blurVibrancy   = Config::getValue<float>(KEY_BLUR_VIBR);
    g_pHyprRenderer->m_renderPass.add(makeUnique<COverviewBlurPassElement>(blur));
}

void renderRunningDot(PHLMONITOR monitor, const SLayout& layout, const SItem& item) {
    const float SCALE = std::max(monitor->m_scale, 0.01F);
    const float SIZE  = std::max(1.F, sc<float>(Config::getValue<int>(KEY_DOT_SIZE)) * SCALE);
    const float CX    = sc<float>(item.iconBox.x) + sc<float>(item.iconBox.width) / 2.F;
    const float TOP   = sc<float>(item.iconBox.y) + sc<float>(item.iconBox.height) + DOT_MARGIN_B * SCALE;

    const uint32_t ARGB = Config::getValue<uint32_t>(KEY_DOT_COLOR);

    // Z12 (user, 2026-08-07, overrides X31's measured single dot): one dot per
    // WINDOW. Row one keeps today's exact position and grows outward from the
    // icon's centre; overflow wraps to a second row underneath; two rows max,
    // and windows beyond that are simply not shown.
    size_t count = 0;
    for (const auto& WINDOW : Desktop::windowState()->windows())
        if (interesting(WINDOW) && WINDOW->m_class == item.wmClass)
            ++count;
    count = std::max<size_t>(count, 1);

    const float  GAP    = 3.F * SCALE;
    const size_t PERROW = std::max<size_t>(1, sc<size_t>((sc<float>(item.iconBox.width) + GAP) / (SIZE + GAP)));
    count               = std::min(count, PERROW * 2);
    const size_t ROW1   = std::min(count, PERROW);
    const size_t ROW2   = count - ROW1;

    const auto drawRow = [&](size_t n, float top) {
        const float SPAN = sc<float>(n) * SIZE + sc<float>(n - 1) * GAP;
        for (size_t i = 0; i < n; ++i) {
            CRectPassElement::SRectData dot;
            dot.box   = CBox{std::round(CX - SPAN / 2.F + sc<float>(i) * (SIZE + GAP)), std::round(top), std::round(SIZE), std::round(SIZE)};
            dot.color = CHyprColor{sc<float>((ARGB >> 16) & 0xFF) / 255.F, sc<float>((ARGB >> 8) & 0xFF) / 255.F, sc<float>(ARGB & 0xFF) / 255.F, sc<float>((ARGB >> 24) & 0xFF) / 255.F};
            // `border-radius: 5px` on a 5px box: a circle. Truncated, not
            // rounded -- a radius even slightly OVER half the box collapses the
            // circle into a diamond (seen on screen 2026-08-03).
            dot.round         = sc<int>(SIZE / 2.F);
            dot.roundingPower = 2.F;
            g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(dot));
        }
    };

    drawRow(ROW1, TOP);
    if (ROW2)
        drawRow(ROW2, TOP + SIZE + std::max(1.F, 2.F * SCALE));
}

// `_notificationBadgeCountToText`, same thresholds and the same rounding.
std::string badgeText(long long count) {
    if (count <= 9999)
        return std::to_string(count);

    char        buf[32] = {};
    const auto  N       = sc<double>(count);
    if (count < 100'000)
        std::snprintf(buf, sizeof(buf), "%.1fk", N / 1e3);
    else if (count < 1'000'000)
        std::snprintf(buf, sizeof(buf), "%.0fk", N / 1e3);
    else if (count < 100'000'000)
        std::snprintf(buf, sizeof(buf), "%.1fM", N / 1e6);
    else if (count < 1'000'000'000)
        std::snprintf(buf, sizeof(buf), "%.0fM", N / 1e6);
    else
        std::snprintf(buf, sizeof(buf), "%.1fB", N / 1e9);

    return buf;
}

void renderBadge(PHLMONITOR monitor, const SItem& item) {
    if (!item.uri.empty()) // X35: a location has no class to key a LauncherEntry on
        return;

    const auto COUNT = badgeCount(item.wmClass);
    if (COUNT <= 0)
        return;

    const float SCALE = std::max(monitor->m_scale, 0.01F);
    const float ICON  = sc<float>(item.iconBox.width) / SCALE; // logical px: what the reference scales by

    // `_updateNotificationBadgeStyle`. The small-icon branch is not dead code --
    // the pill shrinks its icons rather than overflow once it hits the width cap,
    // which is exactly the case D2D's `iconSize < defaultIconSize` covers.
    const float MULT = ICON < BADGE_DEFAULT_ICON ? std::max(24.F, std::min(ICON + ICON * 0.3F, BADGE_DEFAULT_ICON)) / BADGE_DEFAULT_ICON : ICON / BADGE_DEFAULT_ICON;
    const float FONT = std::max(1.F, std::round(MULT * (BADGE_FONT_PT * BADGE_FONT_RATIO / 0.75F)));

    const auto  TEX = OverviewRender::text(badgeText(COUNT), CHyprColor{1.F, 1.F, 1.F, 1.F}, std::max(1, sc<int>(std::round(FONT * SCALE))), false, "", 0, BADGE_WEIGHT);
    if (!TEX || !TEX->ok())
        return;

    const float PADX = std::round(BADGE_PAD_X_EM * FONT * SCALE);
    const float PADY = std::round(BADGE_PAD_Y_EM * FONT * SCALE);
    const float W    = sc<float>(TEX->m_size.x) + 2.F * PADX;
    const float H    = sc<float>(TEX->m_size.y) + 2.F * PADY;

    const float X    = sc<float>(item.iconBox.x) + sc<float>(item.iconBox.width) - W - BADGE_MARGIN * SCALE;
    const float Y    = sc<float>(item.iconBox.y) + BADGE_MARGIN * SCALE;

    CRectPassElement::SRectData bg;
    bg.box   = CBox{std::round(X), std::round(Y), std::round(W), std::round(H)};
    bg.color = CHyprColor{1.F, 0.F, 0.F, 1.F}; // `background-color: red`
    // `border-radius: 1em` -- 1em is the font size, which on a badge this short
    // is always at least half its height, and css clamps a radius to that. So the
    // shape is a capsule, and H/2 is the number that stays one at any count.
    bg.round         = sc<int>(std::round(H / 2.F));
    bg.roundingPower = 2.F;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(bg));

    CTexPassElement::SRenderData text;
    text.tex = TEX;
    text.box = CBox{std::round(X + PADX), std::round(Y + PADY), sc<float>(TEX->m_size.x), sc<float>(TEX->m_size.y)};
    text.a   = 1.F;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CTexPassElement>(text));
}

// X34. The Hot-Key visual aid. `_updateNumberOverlay` numbers the icons 1..9,
// gives the TENTH a `0` -- the digit on its key, not its ordinal -- and leaves
// every icon past that without one.
//
// Reference divergence worth naming: the reference numbers `getAppIcons()`
// (every child with an `.icon`) but ACTIVATES out of a list filtered on
// `.child.app`, so once X35 puts trash and mounts in the dash the number drawn
// on an icon and the slot its key reaches can drift apart. Here both come from
// `LAYOUT.items`, which is ONE list, so they cannot.
void renderNumberOverlay(PHLMONITOR monitor, const SItem& item, int index) {
    if (!overlayUp() || index >= NUM_HOTKEYS)
        return;

    const int   DIGIT = (index + 1) % 10; // the tenth slot is `0`
    const float SCALE = std::max(monitor->m_scale, 0.01F);
    const float ICON  = sc<float>(item.iconBox.width) / SCALE; // logical px, as the reference measures

    const float FONT  = std::round(std::max(NUMBER_FONT_MIN, NUMBER_FONT_RATIO * ICON));
    const float SIZE  = std::round(FONT * NUMBER_BOX_RATIO * SCALE);

    const auto  TEX = OverviewRender::text(std::to_string(DIGIT), CHyprColor{1.F, 1.F, 1.F, 1.F}, std::max(1, sc<int>(std::round(FONT * SCALE))));
    if (!TEX || !TEX->ok())
        return;

    // `ActorAlign.START` on both axes and the CSS adds no margin: flush into the
    // icon's top-left corner.
    const float X = sc<float>(item.iconBox.x);
    const float Y = sc<float>(item.iconBox.y);

    CRectPassElement::SRectData bg;
    bg.box   = CBox{std::round(X), std::round(Y), SIZE, SIZE};
    bg.color = CHyprColor{0.F, 0.F, 0.F, NUMBER_BG_ALPHA};
    // Truncated for the same reason the running dot is: a radius even slightly
    // over half the box collapses the circle into a diamond.
    bg.round         = sc<int>(SIZE / 2.F);
    bg.roundingPower = 2.F;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(bg));

    // `text-align: center`, and vertically too -- the label fills the bin.
    CTexPassElement::SRenderData text;
    text.tex = TEX;
    text.box = CBox{std::round(X + (SIZE - sc<float>(TEX->m_size.x)) / 2.F), std::round(Y + (SIZE - sc<float>(TEX->m_size.y)) / 2.F), sc<float>(TEX->m_size.x),
                    sc<float>(TEX->m_size.y)};
    text.a   = 1.F;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CTexPassElement>(text));
}

// X32. A pinned favourite that is not running has no window class, so the class
// lookup that used to be the whole of this cannot name it -- its desktop entry
// is the only source. Ordered so a running app is still named by its class,
// which is what X27 measured.
std::string itemName(const SItem& item) {
    // X35. A location's name is its own -- no class to look it up by, and the
    // desktop-entry fallback below would answer "Files" for every one of them.
    if (!item.uri.empty())
        return item.locationName;

    if (const auto FROMCLASS = AppSearch::appNameForClass(item.wmClass); !FROMCLASS.empty())
        return FROMCLASS;

    if (const auto* ENTRY = AppSearch::entryForId(item.desktopId); ENTRY && !ENTRY->name.empty())
        return ENTRY->name;

    return item.wmClass;
}

// GNOME's dash label does not appear, it FADES: `_showLabel` eases opacity over
// DASH_ITEM_LABEL_SHOW_TIME. Ours arrived at full alpha, which is what the user
// reported missing. House entrance curve, because this is an entrance.
constexpr float TOOLTIP_FADE_MS     = 150.F;
constexpr float TOOLTIP_FADE_OUT_MS = 110.F; // exits are ~25% quicker, house rule

// The plate outlives the hover so it can fade AWAY; the caller passes an empty
// name when nothing is hovered and this keeps drawing the last one until it has
// gone. Anchor is remembered for the same reason -- the icon it belonged to is
// no longer under the pointer.
struct STooltip {
    std::string     name;
    CBox            anchor;
    float           bottomY = 0.F; // Y2; 0 = hang off the pill
    Time::steady_tp since   = Time::steadyNow();
    bool            out     = false;
};
STooltip g_tip;

// Y2. `bottomY` is the monitor-local RENDER y the plate's underside sits on. 0
// means "the pill", which is every caller that labels an icon. The hover panel
// passes its own top instead, so a preview's title rides above the previews
// rather than behind them.
void renderTooltip(PHLMONITOR monitor, const SLayout& layout, const CBox& anchor, const std::string& NAME, float bottomY = 0.F) {
    if (!NAME.empty()) {
        // The fade restarts when the label CHANGES, so sliding along the dock
        // gives each name its own entrance rather than one fade for the trip.
        if (NAME != g_tip.name || g_tip.out) {
            g_tip.name  = NAME;
            g_tip.since = Time::steadyNow();
            g_tip.out   = false;
        }
        g_tip.anchor = anchor;
        // Y2. Remembered with the anchor and for the same reason: the plate
        // outlives the hover so it can fade away, and by then the cell it was
        // labelling may be gone.
        g_tip.bottomY = bottomY;
    } else {
        if (g_tip.name.empty())
            return;
        if (!g_tip.out) {
            g_tip.out   = true;
            g_tip.since = Time::steadyNow();
        }
    }

    const float T = std::clamp(elapsedMs(g_tip.since) / (g_tip.out ? TOOLTIP_FADE_OUT_MS : TOOLTIP_FADE_MS), 0.F, 1.F);
    if (g_tip.out && T >= 1.F) {
        g_tip.name.clear();
        return;
    }

    // Entrances decelerate, exits accelerate: the house rule, both directions.
    const float ALPHA = g_tip.out ? 1.F - houseEase(false, T) : houseEase(true, T);

    // A pointer resting on an icon emits no motion, so nothing else would ask
    // for the frames this fade needs. Same doLater the live previews use: a
    // damage requested inside the pass is cleared with that pass.
    if (T < 1.F) {
        g_pEventLoopManager->doLater([MONITOR = PHLMONITORREF{monitor}] {
            if (MONITOR)
                g_pHyprRenderer->damageMonitor(MONITOR.lock());
        });
    }

    const float SCALE = std::max(monitor->m_scale, 0.01F);
    const float CX    = sc<float>(g_tip.anchor.x) + sc<float>(g_tip.anchor.width) / 2.F;

    // X57. Drawn by the SHARED pill, the same one the overview tile caption
    // uses -- the host styles both with one css rule and this is that decision
    // in code.
    const float BOTTOM = g_tip.bottomY > 0.F ? g_tip.bottomY : sc<float>(layout.pill.y);
    OverviewRender::labelPill(monitor, g_tip.name, CX, BOTTOM - TOOLTIP_GAP * SCALE, ALPHA, SCALE);
}

// X24. Stash first, then fly. Order matters: minimize() is what stops the
// compositor drawing the real window, so doing it up front is what keeps the
// flight from being a second copy of a window that is still on screen.
// X54. Bring the pill out NOW, skipping show_delay. A flight is 180ms and the
// delay alone is 250, so "ask nicely and wait" meant the animation was over
// before the dock arrived -- and Dock::render returns early on an empty pill, so
// the flight was never drawn at all. The autohide slide still plays; the flight
// simply targets the icon while it moves, which is the right look anyway.
void revealNow(PHLMONITOR monitor) {
    if (!monitor)
        return;

    auto& R = g_reveal[monitor->m_id];
    if (R.shown)
        return;

    R.shown     = true;
    R.pending   = false;
    R.changedAt = Time::steadyNow();
}

// The window as it sits on screen, in the monitor-local RENDER px the flight
// works in.
CBox windowRenderBox(PHLMONITOR monitor, const PHLWINDOW& window) {
    if (!monitor || !window)
        return {};

    const auto POS   = window->m_realPosition->value();
    const auto SIZE  = window->m_realSize->value();
    const auto SCALE = std::max(monitor->m_scale, 0.01F);

    return CBox{(POS.x - monitor->m_position.x) * SCALE, (POS.y - monitor->m_position.y) * SCALE, SIZE.x * SCALE, SIZE.y * SCALE};
}

// Y10. The window END of a flight, which is NOT always the window's desktop
// geometry. With the overview open the user is looking at the TILE, so that is
// what the animation has to leave from and arrive at -- reading the real box
// there made a restore grow out of the icon into a rectangle nothing was drawn
// in. A window whose desktop is scrolled off screen has no tile at all, so the
// flight aims past the edge on the side that desktop lies and the motion still
// reads as "it went that way" rather than collapsing onto a point.
CBox offscreenAimBox(PHLMONITOR monitor, const PHLWINDOW& window) {
    const float SCALE = std::max(monitor->m_scale, 0.01F);
    const float W     = sc<float>(monitor->m_size.x) * SCALE;
    const float H     = sc<float>(monitor->m_size.y) * SCALE;

    // A minimized window sits on the stash, so its own m_workspace cannot say
    // where it came from -- Minimize recorded that and is the only honest source.
    WORKSPACEID home = Minimize::originalWorkspace(window);
    if (home == WORKSPACE_INVALID && window->m_workspace)
        home = window->m_workspace->m_id;

    const auto ACTIVE = monitor->m_activeWorkspace;
    const bool LEFT   = ACTIVE && home != WORKSPACE_INVALID && home < ACTIVE->m_id;

    const float BW = W * 0.25F;
    const float BH = H * 0.25F;

    return CBox{LEFT ? -BW : W, (H - BH) / 2.F, BW, BH};
}

CBox flightAnchorBox(PHLMONITOR monitor, const PHLWINDOW& window) {
    if (!monitor || !window)
        return {};

    if (const auto OVERVIEW = scrollOverviewForMonitor(monitor)) {
        if (CBox tile = OVERVIEW->tileBox(window); tile.width >= 1 && tile.height >= 1)
            return tile;

        // Z8 (user video): a MINIMIZED window has no tile unless Y9's filter is
        // on, so restores fell through to the offscreen aim -- whose
        // home==active case is not LEFT, i.e. it aimed at the NEXT desktop for
        // a window belonging to the very card the user is looking at. Aim at
        // the recorded pre-minimize box transformed into its home card.
        const auto HOMEWS = Minimize::originalWorkspace(window);
        const CBox HOME   = Minimize::originalBox(window);
        if (HOMEWS != WORKSPACE_INVALID && HOME.width >= 1) {
            if (CBox b = OVERVIEW->overviewBoxForGlobal(HOMEWS, HOME); b.width >= 1 && b.height >= 1)
                return b;
        }

        return offscreenAimBox(monitor, window);
    }

    return windowRenderBox(monitor, window);
}

// Z18. "An overview object exists" is NOT "the overview is open": objects
// persist while closing (that is what reopen() is for), and a stuck close
// leaves a zombie registered. Measured: a desktop-only cycle test took the
// overview branch (flightEnd landed=1) because the session had used the
// overview earlier -- every restore since hid the window, the bridge landing
// never warped geometry, and each cycle shrank the window by the abandoned
// flight's last frame (500 -> 410 -> 336 -> 276, x0.82).
//
// The predicate that Z18 forced the dock to invent now lives on the manager,
// next to the registry it filters -- openScrollOverviewForMonitor() -- so no
// other consumer has to re-derive "exists AND not closing" and get it wrong.
// This stays as a local spelling of it.
SP<IOverview> overviewOpenFor(PHLMONITOR monitor) {
    return openScrollOverviewForMonitor(monitor);
}

// Z9 round five. The click-time restore treatment: the window comes off the
// stash FOR REAL -- real focus from focusState, which is why nothing steals
// the keyboard back when other windows exist (round four's seat-only focus
// was a squatter; focusState re-asserted the OTHER window and the client went
// dark again). setHidden(true) keeps the compositor from drawing it for the
// flight; the plugin's own preview paths ignore m_hidden, so the proxy is the
// only image on screen.
CBox restoreForFlight(PHLMONITOR monitor, const PHLWINDOW& window, const CBox& iconBox) {
    Minimize::restore(window);
    warpRestoredWindowAnims(window);
    window->updateDecorationValues();
    if (window->m_borderFadeAnimationProgress)
        window->m_borderFadeAnimationProgress->warp();
    if (window->m_dimPercent)
        window->m_dimPercent->warp();

    if (const auto OVERVIEW = overviewOpenFor(monitor)) {
        // Overview path: proxy machinery, window hidden for the flight (the
        // tile and the proxy share a render pipeline, so that seam is clean).
        window->setHidden(true);
        g_pEventLoopManager->doLater([W = PHLWINDOWREF{window}] {
            if (const auto WIN = W.lock())
                warpRestoredWindowAnims(WIN);
        });
        return {};
    }

    // Capture the layout's target BEFORE parking -- setValueAndWarp moves the
    // GOAL too (hyprutils keeps m_Value private, so there is no value-only
    // write), and reading goal() after parking chased the parked box itself
    // (measured: 121 drive frames pinned at the icon). The flight freezes this
    // target in SFlight.from; a retile mid-flight lands via the closing warp.
    const auto  GOALPOS = window->m_realPosition->goal();
    const auto  GOALSZ  = window->m_realSize->goal();
    const float SCALE   = std::max(monitor->m_scale, 0.01F);
    const CBox  TARGET{(GOALPOS.x - monitor->m_position.x) * SCALE, (GOALPOS.y - monitor->m_position.y) * SCALE, GOALSZ.x * SCALE, GOALSZ.y * SCALE};

    // Z17 (user: "are we not using the real windows, like the rest of the
    // overview"). Desktop path: NO proxy, no hidden flag. The real window is
    // the animation -- parked at the icon at alpha 0, then its animated
    // variables are driven along the flight curve each frame while the
    // compositor renders it natively: real shadow, real border, real blur,
    // focused. A proxy hand-off cannot be seamless because the two renderings
    // differ (measured: a 3.2M-luminance seam frame at landing); a window that
    // was never swapped has no seam.
    if (iconBox.width >= 1) {
        window->m_realPosition->m_Value = Vector2D{iconBox.x / SCALE + monitor->m_position.x, iconBox.y / SCALE + monitor->m_position.y};
        window->m_realSize->m_Value     = Vector2D{std::max(4.0, iconBox.width / SCALE), std::max(4.0, iconBox.height / SCALE)};
    }
    window->alpha()[Desktop::View::WINDOW_ALPHA_FADE]->setValueAndWarp(0.F);
    return TARGET;
}

// Z5. If this window is mid-flight, flip the flight's direction in place: the
// new motion starts at the proxy's last drawn box and alpha, so a spam of
// clicks reads as one object changing its mind, which is what GNOME does. The
// window's stash state is untouched -- it is stashed for the whole life of
// either flight kind, and only a LANDED restore changes that.
// Flight lifecycle log, off by default. scripts/z_rig.sh turns it on and
// scripts/zflight_gate.py (host) reads it: the z5 reversal gate judges the
// DRAWN boxes around each reversal, because a 400ms EASE_OUT_EXPO legitimately
// moves ~900px between two 30fps film frames and no pixel metric can tell that
// from a teleport. Plain fopen because the plugin's Log::logger is dead
// (separate inline instance under -fno-gnu-unique).
constexpr const char* KEY_FLIGHT_LOG = "plugin:scrolloverview:dock:flight_log";

static void zdbg(const char* fmt, ...) {
    if (!Config::getValue<bool>(KEY_FLIGHT_LOG))
        return;
    if (FILE* F = fopen("/tmp/ovdbg.log", "a")) {
        va_list ap; va_start(ap, fmt); vfprintf(F, fmt, ap); va_end(ap); fclose(F);
    }
}

// Z15 (user): defined after g_panel below; a flight click kills the hover
// panel INSTANTLY. Leaving it alive re-eased it from a stale parked box, which
// read as "a panel dragged from the bottom of the screen" under the restore.
void dismissHoverPanelNow();

bool reverseFlight(const PHLWINDOW& window, bool restoring) {
    const auto IT = std::ranges::find_if(g_flights, [&window](const auto& f) { return f.window.lock() == window; });
    zdbg("reverse(%d) found=%d landing=%d lastA=%f\n", (int)restoring, IT != g_flights.end(), IT == g_flights.end() ? -9 : (int)IT->isLanding(), IT == g_flights.end() ? -9.F : IT->lastAlpha);
    // Reverse UNLESS the flight is already landing (past the point where the
    // motion means anything). It used to also bail when lastAlpha < 0 -- a
    // flight that had not drawn a frame yet -- but that was a strand: the caller
    // then started a FRESH flight without this one being erased, so two flights
    // for one window fought in the render loop and the toggle ended in the wrong
    // state. A click can beat the first frame under spam on a slow output (z5),
    // and a never-drawn flight has no visible proxy to be discontinuous with, so
    // the empty lastDrawn / negative lastAlpha below simply fall through to the
    // render loop's fresh-flight defaults (START = icon/from, default alpha).
    if (IT == g_flights.end() || IT->isLanding())
        return false;

    const SFlight OLD = *IT;
    g_flights.erase(IT);

    // Z9r5: state flips WITH the direction. A restoring flight's window is
    // already real -- sending it back means stash (plus unhide on the overview
    // path). The minimize->restore direction is handled by the caller via
    // restoreForFlight, which needs the monitor.
    if (!restoring && !Minimize::isMinimized(window)) { // reversing back to a minimize
        // Z17: a DRIVEN flight moved goal AND value to the mid-air box; stashing
        // now would record that as the window's geometry and a later restore
        // would bring it back shrunken. Re-goal to the flight's true target
        // (OLD.from, render px) before the stash captures it.
        if (const auto MON = window->m_monitor.lock(); MON && OLD.from.width >= 1 && !window->isHidden()) {
            const float SCALE = std::max(MON->m_scale, 0.01F);
            window->m_realPosition->m_Value = Vector2D{OLD.from.x / SCALE + MON->m_position.x, OLD.from.y / SCALE + MON->m_position.y};
            window->m_realSize->m_Value     = Vector2D{std::max(4.0, OLD.from.width / SCALE), std::max(4.0, OLD.from.height / SCALE)};
        }
        window->alpha()[Desktop::View::WINDOW_ALPHA_FADE]->setValueAndWarp(1.F);
        window->setHidden(false);
        Minimize::minimize(window, false); // keep focus: the flight hands off at landing
    }

    // A reversed flight is always a proxy (never driven): the desktop-driven
    // restore only starts from restoreWithFlightImpl, not from a reversal.
    g_flights.emplace_back(SFlight{.window    = window,
                                   .from      = OLD.from,
                                   .kind      = restoring ? EFlightKind::RestoreProxy : EFlightKind::MinimizeProxy,
                                   .startedAt = Time::steadyNow(),
                                   .start     = OLD.lastDrawn,
                                   .alphaFrom = OLD.lastAlpha});
    return true;
}

void minimizeWithFlightImpl(PHLMONITOR monitor, PHLWINDOW window, bool bounceOnLand = false) {
    // Z5/Z9r5. Mid-restore click: put it back from mid-air. The window is
    // REAL (hidden) during a restore flight now, so the gate is the flight's
    // existence, and reverseFlight performs the unhide + stash.
    if (window && reverseFlight(window, false))
        return;

    const int  DURATION = Config::getValue<int>(KEY_MINIMIZE_MS);
    const bool ANIMATE  = monitor && window && DURATION > 0 && !Minimize::isMinimized(window);

    // Must be read before the stash, which moves the window off its workspace
    // and so destroys both the tile and the real box.
    CBox from;
    if (ANIMATE)
        from = flightAnchorBox(monitor, window);

    // Keep focus only when a flight will actually play (ANIMATE); the flight
    // hands off at its landing. With no flight there is nothing to stay bright
    // for, so hand off immediately like any other minimize.
    Minimize::minimize(window, !ANIMATE);
    // Z14 (user): "the window shadows do not follow it down" -- the stash move
    // arms MOVE_FROM_WORKSPACE / fade animations that draw the real window
    // (shadow included) fading at its OLD rect while the proxy departs. The
    // flight is the animation; warp them all.
    if (ANIMATE)
        warpRestoredWindowAnims(window);
    zdbg("minimizeImpl animate=%d from=%f,%f %fx%f\n", (int)ANIMATE, from.x, from.y, from.width, from.height);

    dismissHoverPanelNow(); // Z15
    if (ANIMATE && from.width >= 1 && from.height >= 1) {
        if (overviewOpenFor(monitor))
            rememberMinimizeTile(window, from); // Z13: `from` IS the tile here
        revealNow(monitor);
        // Z10 (user, overriding Y8's "macOS bounces what arrives"): the hop is
        // the ACKNOWLEDGEMENT of the drop, so it fires now, while the window
        // is still flying in -- not at the landing.
        if (bounceOnLand)
            g_bounces.emplace_back(SBounce{.wmClass = window->m_class, .startedAt = Time::steadyNow()});
        std::erase_if(g_flights, [&window](const auto& f) { return f.window.lock() == window; });
        g_flights.emplace_back(SFlight{.window = window, .from = from, .kind = EFlightKind::MinimizeProxy, .startedAt = Time::steadyNow()});
    }
}

// X54. The mirror of the minimize, and it has to keep the window STASHED for
// the length of the flight: restoring first would put the real window on screen
// instantly and the proxy would be a second copy of it. The actual restore
// happens when the flight lands -- see the render loop.
void restoreWithFlightImpl(PHLMONITOR monitor, PHLWINDOW window) {
    // Z5. Mid-minimize click: bring it straight back from mid-air -- and give
    // it the same click-time restore treatment a fresh flight gets (Z9r5).
    if (window && reverseFlight(window, true)) {
        if (monitor && Minimize::isMinimized(window)) {
            const CBox TARGET = restoreForFlight(monitor, window, CBox{});
            const auto IT     = std::ranges::find_if(g_flights, [&window](const auto& f) { return f.window.lock() == window; });
            if (IT != g_flights.end()) {
                // restoreForFlight may have un-hidden the real window (desktop
                // path): upgrade the reversed proxy to a driven flight to match.
                IT->kind = window->isHidden() ? EFlightKind::RestoreProxy : EFlightKind::RestoreDriven;
                if (TARGET.width >= 1)
                    IT->from = TARGET;
            }
        }
        return;
    }

    const int DURATION = Config::getValue<int>(KEY_MINIMIZE_MS);
    zdbg("restoreImpl dur=%d mon=%d min=%d\n", DURATION, (int)(bool)monitor, window ? (int)Minimize::isMinimized(window) : -9);

    if (!monitor || !window || DURATION <= 0 || !Minimize::isMinimized(window)) {
        Minimize::restore(window);
        return;
    }

    // Z6 (user, 2026-08-07): a restore to ANOTHER desktop used to aim the
    // flight off the screen edge and let Minimize::restore snap the workspace
    // at landing -- "maximizing in the wrong place". GNOME switches first, so
    // switch NOW and fly to the real box while the workspace slide plays
    // underneath; both are monitor-anchored, so they compose. The overview
    // path keeps its tile aim -- there the user is looking at the cards, and
    // the strip is the thing that says which desktop a tile is on.
    if (!overviewOpenFor(monitor)) {
        const auto HOME = Minimize::originalWorkspace(window);
        if (HOME != WORKSPACE_INVALID && monitor->m_activeWorkspace && monitor->m_activeWorkspace->m_id != HOME)
            Minimize::showOriginalWorkspace(window);
    }

    // Y10/Z13. With the overview up, aim at the tile the window occupied when
    // it was minimized (recorded) -- overviewBoxForGlobal was the DESKTOP box
    // scaled into the card, which is not where the grid puts a tile, so the
    // landing snapped. On the DESKTOP path, flightAnchorBox would read the
    // stash workspace's own retile -- aim at the recorded pre-minimize box
    // instead ("slight bug on first maximize", user video 2026-08-07 11:02).
    // The landing hold covers whatever the layout re-decides.
    CBox TO{};
    if (overviewOpenFor(monitor))
        TO = takeMinimizeTile(window);
    if (TO.width < 1 || TO.height < 1)
        TO = flightAnchorBox(monitor, window);
    if (!scrollOverviewForMonitor(monitor)) {
        const CBox HOME = Minimize::originalBox(window); // global logical
        if (HOME.width >= 1 && HOME.height >= 1) {
            const float SCALE = std::max(monitor->m_scale, 0.01F);
            TO = CBox{(HOME.x - monitor->m_position.x) * SCALE, (HOME.y - monitor->m_position.y) * SCALE, HOME.width * SCALE, HOME.height * SCALE};
        }
    }
    if (TO.width < 1 || TO.height < 1) {
        Minimize::restore(window);
        return;
    }

    dismissHoverPanelNow(); // Z15

    {
        const float SCALE = std::max(monitor->m_scale, 0.01F);
        const float MW    = sc<float>(monitor->m_size.x) * SCALE;
        const float MH    = sc<float>(monitor->m_size.y) * SCALE;
        // parked box: the dock band's centre. It is on screen for 0-1 frames at
        // alpha 0 before the first driven frame -- placement is cosmetic.
        const CBox TARGET = restoreForFlight(monitor, window, CBox{MW / 2.F - 27.F, MH - 80.F, 54.F, 54.F});
        if (TARGET.width >= 1)
            TO = TARGET;
    }

    revealNow(monitor);
    // Desktop path (window not hidden) drives the real window natively (Z17);
    // overview path (hidden) draws a proxy. The kind is frozen here for the
    // whole flight -- Z18: re-deriving it per frame flipped it mid-flight.
    std::erase_if(g_flights, [&window](const auto& f) { return f.window.lock() == window; });
    g_flights.emplace_back(SFlight{.window    = window,
                                   .from      = TO,
                                   .kind      = window->isHidden() ? EFlightKind::RestoreProxy : EFlightKind::RestoreDriven,
                                   .startedAt = Time::steadyNow()});
}

// X24's click policy, straight off the reference config: `click-action`
// minimize, `activate-single-window` true, `minimize-shift` true,
// `shift-click-action` minimize.
//
// X32 adds the LAUNCH branch, which X27 could not have: a pinned favourite owns
// no window, so `click-action` has nothing to minimize and the reference falls
// through to launching the app.
std::vector<PHLWINDOW> classWindows(const std::string& wmClass) {
    if (wmClass.empty())
        return {};

    std::vector<PHLWINDOW> out;
    for (const auto& WINDOW : Desktop::windowState()->windows()) {
        if (interesting(WINDOW) && WINDOW->m_class == wmClass)
            out.emplace_back(WINDOW);
    }

    return out;
}

// The reference's `Main.activateWindow`, which is what every X33 path ends in.
// Focus alone is not enough: the window may be on another desktop, it may be
// minimized, and X43 already established that focus and stacking are separate
// questions.
void activateWindow(const PHLWINDOW& window) {
    if (!window)
        return;

    if (Minimize::isMinimized(window)) {
        Minimize::restore(window);
        return;
    }

    if (const auto WORKSPACE = window->m_workspace; WORKSPACE) {
        if (const auto MONITOR = WORKSPACE->m_monitor.lock(); MONITOR && MONITOR->m_activeWorkspace != WORKSPACE)
            MONITOR->changeWorkspace(WORKSPACE, false, true, true);
    }

    Desktop::windowState()->raise(window);
    Desktop::focusState()->fullWindowFocus(window, Desktop::FOCUS_REASON_KEYBIND);
}

// X33 `scroll-action='cycle-windows'`, transcribed from `_cycleThroughWindows`.
//
// The list is REMEMBERED for CYCLE_MEMORY_MS rather than recomputed per tick,
// and that is the entire subtlety of the feature: activating a window reorders
// the compositor's stack, so a cycle driven off a freshly-read order would step
// between the same two windows forever. The memory is dropped when the app
// changes or the app's window COUNT changes -- the reference's own staleness
// test, which deliberately does not notice a reorder.
struct SCycle {
    std::string               wmClass;
    std::vector<PHLWINDOWREF> windows;
    int                       index = 0;
    Time::steady_tp           at;
};

std::optional<SCycle> g_cycle;

void cycleThroughWindows(const std::string& wmClass, bool reversed) {
    const auto WINDOWS = classWindows(wmClass);
    if (WINDOWS.empty())
        return;

    const bool STALE = !g_cycle || g_cycle->wmClass != wmClass || g_cycle->windows.size() != WINDOWS.size() || elapsedMs(g_cycle->at) > CYCLE_MEMORY_MS;

    if (STALE) {
        g_cycle = SCycle{.wmClass = wmClass, .index = 0};
        g_cycle->windows.reserve(WINDOWS.size());
        for (const auto& WINDOW : WINDOWS)
            g_cycle->windows.emplace_back(WINDOW);
    }

    g_cycle->at = Time::steadyNow();

    const int COUNT = sc<int>(g_cycle->windows.size());
    g_cycle->index  = reversed ? (g_cycle->index - 1 + COUNT) % COUNT : (g_cycle->index + 1) % COUNT;

    // A window can die while the memory still holds it. Dropping the memory
    // rather than skipping the slot keeps the index and the list in step.
    const auto WINDOW = g_cycle->windows[g_cycle->index].lock();
    if (!WINDOW) {
        g_cycle.reset();
        return;
    }

    activateWindow(WINDOW);
}

// The reference's shared entry point for a cycle: if the app already has focus
// and nothing of it is shouting, step to its next window; otherwise the gesture
// is simply "bring this app forward", which is what an urgent window wants.
void cycleOrActivate(const std::string& wmClass, bool reversed) {
    const auto WINDOWS = classWindows(wmClass);
    if (WINDOWS.empty())
        return;

    const auto FOCUSED = Desktop::focusState()->window();
    const bool OWNSFOCUS = FOCUSED && FOCUSED->m_class == wmClass;

    if (OWNSFOCUS && !classUrgent(wmClass))
        cycleThroughWindows(wmClass, reversed);
    else
        activateWindow(WINDOWS.front());
}

// The overview gets out of the way, because a window that maps behind an open
// overview is a window the user cannot see they just started.
//
// X33 gave this a second caller and with it a second way to be asked: a RUNNING
// app middle-clicked for a new window owns a class but need not own a favourite,
// so `desktopId` can be empty where `idForClass` still answers.
// Z11 (user): spam-clicking a launcher must REPLAY the blow-up but exec ONE
// instance. The vulnerable window is exec -> first map: once a window exists,
// clicks take the toggle branch and never reach here. 30s covers a cold app;
// a slower one gets a deliberate second chance.
// ponytail: plain timestamps, no startup-notification protocol.
std::unordered_map<std::string, Time::steady_tp> g_pendingLaunches;
constexpr float                                  LAUNCH_PENDING_MS = 30000.F;

void launchApp(PHLMONITOR monitor, const SItem& item) {
    // Y6. Armed here rather than in activateItem so every path that actually
    // starts something gets the blow-up -- a click on a closed app, a hotkey,
    // and `middle-click-action=launch` alike. GNOME calls animateLaunch() from
    // the same place, on activation rather than on the branch that chose it.
    if (!item.icon.empty() && item.iconBox.width >= 1 && item.iconBox.height >= 1)
        g_launchZooms.emplace_back(SLaunchZoom{.icon = item.icon, .from = item.iconBox, .startedAt = Time::steadyNow()});

    const bool  FIRSTINSTANCE = item.uri.empty() ? classWindows(item.wmClass).empty() : true;
    const auto  PENDKEY       = !item.uri.empty() ? item.uri : (item.desktopId.empty() ? item.wmClass : item.desktopId);
    if (FIRSTINSTANCE && !PENDKEY.empty()) {
        if (const auto IT = g_pendingLaunches.find(PENDKEY); IT != g_pendingLaunches.end() && elapsedMs(IT->second) < LAUNCH_PENDING_MS)
            return; // the zoom above replays; the exec does not
        g_pendingLaunches[PENDKEY] = Time::steadyNow();
    }

    // X35. `new-window` on a location is opening it -- the reference's fake
    // ShellApp answers `open_new_window` with the same `launch` either way.
    if (!item.uri.empty()) {
        Locations::activate(item.uri);

        if (const auto OVERVIEW = scrollOverviewForMonitor(monitor); OVERVIEW)
            OVERVIEW->close();

        return;
    }

    const auto  ID    = item.desktopId.empty() ? AppSearch::idForClass(item.wmClass) : item.desktopId;
    const auto* ENTRY = AppSearch::entryForId(ID);
    if (!ENTRY)
        return;

    AppSearch::launch(*ENTRY, Config::getTerminal());

    if (const auto OVERVIEW = scrollOverviewForMonitor(monitor); OVERVIEW)
        OVERVIEW->close();
}

void activateItem(PHLMONITOR monitor, const SItem& item, bool shift, bool ctrl = false) {
    // X35. A location has no windows to minimize: it is opened. Nautilus raises
    // the window it already has for a location rather than opening a second
    // one, so this is the reference's "focus it" too.
    if (!item.uri.empty()) {
        launchApp(monitor, item);
        return;
    }

    const auto windows = classWindows(item.wmClass);

    // Y4. NO WINDOWS: launch. X45's first branch, and the only one it keeps.
    if (windows.empty()) {
        launchApp(monitor, item);
        return;
    }

    // Y4. CTRL is now the ONLY thing that cycles. This replaces X45's
    // count-based branch, where two-or-more windows made a plain click cycle and
    // there was consequently no gesture that could put a multi-window app away.
    // activateWindow() restores a minimized window on the way, so the cycle
    // still reaches windows sitting in the icon as well as windows on screen.
    if (ctrl) {
        cycleThroughWindows(item.wmClass, false);
        return;
    }

    // Y4. Otherwise the click is a toggle over the WHOLE app whatever the count:
    // anything visible goes down, and when there is nothing left visible the
    // next click brings all of it back. This is what `minimize-shift` used to
    // mean, promoted to the default -- so SHIFT and a plain click have converged
    // and `shift` is deliberately not consulted below.
    //
    // Decided by the WINDOWS' own state, not by focus. X45 measured why: the
    // overview owns the focus while it is up, so focusState()->window() is never
    // a dock app's window and a focus test made the minimize branch dead.
    std::vector<PHLWINDOW> visible;
    for (const auto& WINDOW : windows) {
        if (!Minimize::isMinimized(WINDOW))
            visible.emplace_back(WINDOW);
    }

    // Z5. A window mid-RESTORE-flight still reads as minimized (it stays
    // stashed until landing), so without this a spam of clicks re-restored
    // forever instead of toggling. Count it as visible; minimizeWithFlightImpl
    // then reverses its flight in place.
    bool anyFlight = false;
    for (const auto& WINDOW : windows) {
        const auto IT = std::ranges::find_if(g_flights, [&WINDOW](const auto& f) { return f.window.lock() == WINDOW; });
        if (IT == g_flights.end())
            continue;
        anyFlight = true;
        if (IT->isRestore() && Minimize::isMinimized(WINDOW))
            visible.emplace_back(WINDOW);
    }

    // Z7 (user, 2026-08-07): "if window is open in another workspace, instead
    // of the functionality being minimize, just go to that workspace and focus
    // the window. Then it's ok to minimize/maximize." So: visible windows, none
    // of them on THIS workspace, nothing mid-flight -> the click is a GO-THERE,
    // not a minimize. activateWindow already is the reference's
    // Main.activateWindow: switch, raise, focus.
    if (!anyFlight && !visible.empty() && monitor && monitor->m_activeWorkspace) {
        const bool ANYHERE = std::ranges::any_of(visible, [&](const PHLWINDOW& w) { return w->m_workspace == monitor->m_activeWorkspace; });
        if (!ANYHERE) {
            activateWindow(visible.front());
            return;
        }
    }

    if (visible.empty()) {
        for (const auto& WINDOW : windows)
            restoreWithFlightImpl(monitor, WINDOW);
        return;
    }

    for (const auto& WINDOW : visible)
        minimizeWithFlightImpl(monitor, WINDOW);
}

// X33. `middle-click-action` and `shift-middle-click-action`, both `launch` in
// the reference.
//
// The structure is the reference's, not a switch of my own: the whole action
// table lives inside `if (this.running)`, and a NOT-running app ignores the
// setting entirely and just launches. That is why the empty check comes first
// and takes no notice of `action`.
//
// `minimize` routes back through activateItem so the two buttons cannot drift
// apart -- it is the left button's action, and a user who sets middle to
// `minimize` means that one.
void applyClickAction(PHLMONITOR monitor, const SItem& item, const std::string& action, bool shift) {
    // X35. Every one of the reference's five actions is about an app's windows,
    // and a location has none -- `launch` is the only one it can answer, and
    // opening it is what that means here.
    if (!item.uri.empty()) {
        activateItem(monitor, item, shift);
        return;
    }

    const auto WINDOWS = classWindows(item.wmClass);

    if (WINDOWS.empty()) {
        launchApp(monitor, item);
        return;
    }

    if (action == "launch")
        launchApp(monitor, item);
    else if (action == "minimize")
        activateItem(monitor, item, shift);
    else if (action == "cycle-windows")
        cycleOrActivate(item.wmClass, false);
    else if (action == "quit") {
        for (const auto& WINDOW : WINDOWS)
            WINDOW->sendClose();
    } else if (action == "skip")
        activateWindow(WINDOWS.front());
}

// ---------------------------------------------------------------- X28 menu --

enum class ERow : uint8_t { Separator, Action, Window, Details, Favorite, Quit, EmptyTrash, Mount, Unmount, Eject };

struct SRow {
    ERow         kind = ERow::Separator;
    std::string  label;
    std::string  exec;   // ERow::Action
    PHLWINDOWREF window; // ERow::Window
    CBox         box;    // monitor-local RENDER px, filled by renderMenu
};

struct SMenu {
    MONITORID monitor = MONITOR_INVALID;

    // X35. The whole item, not just its class: a location has no class, and the
    // rows it opens are decided by its uri/mount/trashEmpty instead.
    SItem             item;
    CBox              anchor; // the icon cell the menu hangs off
    CBox              box;    // the whole plate, filled by renderMenu
    std::vector<SRow> rows;
};

std::optional<SMenu> g_menu;

// Back off to a lead byte so a truncated title cannot end mid-codepoint and
// hand the text renderer a broken string.
std::string elide(const std::string& text) {
    if (text.size() <= MENU_LABEL_MAX)
        return text;

    size_t cut = MENU_LABEL_MAX;
    while (cut > 0 && (sc<unsigned char>(text[cut]) & 0xC0) == 0x80)
        --cut;

    return text.substr(0, cut) + "…";
}

// Spec §13.9 X28, in the order the spec lists them: .desktop Actions, window
// list, Show Details, Add/Remove from Favorites, Quit.
std::vector<SRow> buildRows(const SItem& item) {
    std::vector<SRow> rows;

    // X35. A location's menu is its `list_actions()` and nothing else -- no
    // window list, no favourite, no Quit: none of those has an answer for a
    // thing that is not an app. An empty trash lists no action at all, so its
    // menu is a bare plate, which is what the reference shows too.
    if (!item.uri.empty()) {
        if (item.mount) {
            // An fstab point that is not up yet offers the opposite action --
            // and no Eject, because there is nothing mounted to eject.
            if (!item.mounted)
                rows.emplace_back(SRow{.kind = ERow::Mount, .label = "Mount"});
            else {
                rows.emplace_back(SRow{.kind = ERow::Unmount, .label = "Unmount"});
                if (item.canEject)
                    rows.emplace_back(SRow{.kind = ERow::Eject, .label = "Eject"});
            }
        } else if (!item.trashEmpty)
            rows.emplace_back(SRow{.kind = ERow::EmptyTrash, .label = "Empty Trash"});

        return rows;
    }

    const auto& wmClass = item.wmClass;

    for (const auto& ACTION : AppSearch::actionsForClass(wmClass))
        rows.emplace_back(SRow{.kind = ERow::Action, .label = ACTION.name, .exec = ACTION.exec});

    const auto WINDOWS = classWindows(wmClass);
    if (!rows.empty() && !WINDOWS.empty())
        rows.emplace_back(SRow{.kind = ERow::Separator});

    for (const auto& WINDOW : WINDOWS)
        rows.emplace_back(SRow{.kind = ERow::Window, .label = elide(WINDOW->m_title.empty() ? wmClass : WINDOW->m_title), .window = WINDOW});

    // A class no desktop entry claims has nothing to show the details of and
    // nothing to favourite by id, so both rows are left out rather than drawn
    // dead. GNOME does the same with an unmatched window.
    if (const auto ID = AppSearch::idForClass(wmClass); !ID.empty()) {
        if (!rows.empty())
            rows.emplace_back(SRow{.kind = ERow::Separator});

        rows.emplace_back(SRow{.kind = ERow::Details, .label = "Show Details"});
        rows.emplace_back(SRow{.kind  = ERow::Favorite,
                               .label = std::ranges::contains(favorites(), ID) ? "Remove from Favorites" : "Add to Favorites"});
    }

    if (!rows.empty())
        rows.emplace_back(SRow{.kind = ERow::Separator});
    rows.emplace_back(SRow{.kind = ERow::Quit, .label = WINDOWS.size() > 1 ? "Quit " + std::to_string(WINDOWS.size()) + " Windows" : "Quit"});

    return rows;
}

void activateRow(PHLMONITOR monitor, const SItem& item, const SRow& row) {
    const auto& wmClass = item.wmClass;

    switch (row.kind) {
        case ERow::Separator: return;

        case ERow::EmptyTrash: Locations::emptyTrash(); return;
        case ERow::Mount: Locations::mount(item.uri); return;
        case ERow::Unmount: Locations::unmount(item.uri, false); return;
        case ERow::Eject: Locations::unmount(item.uri, true); return;

        case ERow::Action: AppSearch::launchExec(row.exec); return;

        case ERow::Window: {
            const auto WINDOW = row.window.lock();
            if (!WINDOW)
                return;

            // ponytail: a minimized window is only restored, not selected. The
            // overview has no card for the stash workspace, so committing a
            // selection onto it would land the viewport on the wrong desktop.
            // Same as clicking its X25 preview, which is the gesture next to it.
            if (Minimize::isMinimized(WINDOW)) {
                Minimize::restore(WINDOW);
                return;
            }

            if (const auto OVERVIEW = scrollOverviewForMonitor(monitor); OVERVIEW)
                OVERVIEW->selectAndClose(WINDOW);
            return;
        }

        case ERow::Details: {
            // What GNOME's own Show Details does. Absent gnome-software this
            // spawns nothing, exactly as it does on a host without it.
            const auto ID = AppSearch::idForClass(wmClass);
            if (!ID.empty())
                AppSearch::launchExec("gnome-software --details=" + ID);
            return;
        }

        case ERow::Favorite: toggleFavorite(AppSearch::idForClass(wmClass)); return;

        case ERow::Quit:
            for (const auto& WINDOW : classWindows(wmClass))
                WINDOW->sendClose();
            return;
    }
}

// Lays the rows out AND draws them: a row's height is its text's height, and
// the only way to learn that is to build the texture. Doing both here is what
// keeps the hit-test boxes and the pixels the user sees the same numbers.
void renderMenu(PHLMONITOR monitor, const SLayout& layout) {
    if (!g_menu || !monitor || g_menu->monitor != monitor->m_id)
        return;

    const float SCALE  = std::max(monitor->m_scale, 0.01F);
    const int   FONTPX = std::max(1, sc<int>(std::round(MENU_FONT * SCALE)));

    std::vector<SP<Render::ITexture>> textures;
    textures.reserve(g_menu->rows.size());

    float width = MENU_MIN_W * SCALE;
    float height = 0.F;
    for (const auto& ROW : g_menu->rows) {
        if (ROW.kind == ERow::Separator) {
            textures.emplace_back(nullptr);
            height += MENU_SEP_H * SCALE;
            continue;
        }

        auto tex = OverviewRender::text(ROW.label, CHyprColor{1.F, 1.F, 1.F, 0.95F}, FONTPX, false, "", 0, 500);
        if (!tex || !tex->ok()) {
            textures.emplace_back(nullptr);
            height += MENU_SEP_H * SCALE;
            continue;
        }

        width  = std::max(width, sc<float>(tex->m_size.x) + 2.F * MENU_PAD_X * SCALE);
        height += sc<float>(tex->m_size.y) + 2.F * MENU_ROW_PAD_Y * SCALE;
        textures.emplace_back(std::move(tex));
    }

    if (height < 1.F)
        return;

    const float CX = sc<float>(g_menu->anchor.x) + sc<float>(g_menu->anchor.width) / 2.F;
    CBox        plate{std::round(CX - width / 2.F), std::round(sc<float>(layout.pill.y) - MENU_GAP * SCALE - height), std::round(width), std::round(height)};
    plate.x = std::clamp(plate.x, 0.0, std::max(0.0, monitor->m_size.x * SCALE - plate.width));
    plate.y = std::max(0.0, plate.y);

    g_menu->box = plate;

    // X13/X29/X86: menu frost -- shared chrome sample in overview, live on desktop.
    queueDockFrost(monitor, plate, sc<int>(std::round(MENU_RADIUS * SCALE)), 1.F);

    CRectPassElement::SRectData bg;
    bg.box           = plate;
    bg.color         = background();
    bg.round         = sc<int>(std::round(MENU_RADIUS * SCALE));
    bg.roundingPower = 2.F;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(bg));

    const auto MOUSE = (g_pInputManager->getMouseCoordsInternal() - monitor->m_position) * monitor->m_scale;

    float y = sc<float>(plate.y);
    for (size_t i = 0; i < g_menu->rows.size(); ++i) {
        auto&      row = g_menu->rows[i];
        const auto TEX = textures[i];

        if (!TEX) {
            row.box = CBox{plate.x, std::round(y), plate.width, std::round(MENU_SEP_H * SCALE)};

            CRectPassElement::SRectData sep;
            sep.box   = CBox{std::round(plate.x + MENU_PAD_X * SCALE), std::round(y + MENU_SEP_H * SCALE / 2.F),
                             std::round(plate.width - 2.F * MENU_PAD_X * SCALE), sc<double>(std::max(1.F, std::round(SCALE)))};
            sep.color = CHyprColor{1.F, 1.F, 1.F, 0.15F};
            g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(sep));

            y += MENU_SEP_H * SCALE;
            continue;
        }

        const float ROWH = sc<float>(TEX->m_size.y) + 2.F * MENU_ROW_PAD_Y * SCALE;
        row.box          = CBox{plate.x, std::round(y), plate.width, std::round(ROWH)};

        if (row.box.containsPoint(MOUSE)) {
            // X56: the context menu's row highlight follows the theme too.
            const auto ROWACCENT = ScrollOverview::Config::highlightColor();

            CRectPassElement::SRectData fill;
            fill.box           = row.box;
            fill.color         = ROWACCENT.modifyA(0.26F);
            fill.round         = 0;
            fill.roundingPower = 2.F;
            g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(fill));
        }

        CTexPassElement::SRenderData text;
        text.tex = TEX;
        text.box = CBox{std::round(plate.x + MENU_PAD_X * SCALE), std::round(y + MENU_ROW_PAD_Y * SCALE), sc<float>(TEX->m_size.x), sc<float>(TEX->m_size.y)};
        text.a   = 1.F;
        g_pHyprRenderer->m_renderPass.add(makeUnique<CTexPassElement>(text));

        y += ROWH;
    }
}

} // namespace

void feedPointerMotion(const Vector2D& delta) {
    const auto POINT = g_pInputManager->getMouseCoordsInternal();

    for (const auto& MONITOR : State::monitorState()->monitors()) {
        if (!MONITOR)
            continue;

        auto&      R   = g_reveal[MONITOR->m_id];
        const auto BOX = MONITOR->logicalBox();

        // Pressure does not carry: leave the barrier, or the monitor, and the
        // push starts again from zero.
        if (!BOX.containsPoint(POINT) || POINT.y < BOX.y + BOX.h - EDGE_BAND)
            R.pressure = 0.F;
        else
            R.pressure += sc<float>(std::max(0.0, delta.y)); // only DOWNWARD motion presses a bottom edge

        // Not updateAutohide: this must also pump the frame that the flip it may
        // have just armed needs, and damageIfChanged is where that lives.
        damageIfChanged(MONITOR);
    }
}

// ------------------------------------------------ X32 reorder, G12 drop --

namespace {

// The dock's own drag, expressed in the store's unit: a press over an icon with
// no desktop id (a preview, the button, the pill's padding, a running app no
// entry claims) records nothing and can never become a drag, because there
// would be nothing to write.
struct SDockDrag {
    std::string id;
    Vector2D    start;
    bool        live   = false;
    int         insert = -1;
};

std::optional<SDockDrag> g_drag;

// G12's caret. A foreign drag keeps its own state in the search panel and only
// ever hands the dock the index to draw, so the two sources cannot both think
// they own the gesture.
int g_foreignInsert = -1;

// Deliberately the overview's own threshold: two drags on one screen that start
// at different distances would read as one of them being sticky.
float dragThresholdPx(PHLMONITOR monitor) {
    return Config::getDragThreshold() * std::max(monitor ? sc<float>(monitor->m_scale) : 1.F, 0.01F);
}

// The favourite slots, in draw order. Only these take part in a reorder: a
// running app that is not pinned has no stored position to move, and the
// stretch of pill it occupies means "after the last favourite" -- which is what
// size() is.
std::vector<size_t> favoriteSlots(const SLayout& layout) {
    std::vector<size_t> out;
    for (size_t i = 0; i < layout.items.size(); ++i)
        if (layout.items[i].favorite)
            out.emplace_back(i);
    return out;
}

int caretIndex() {
    return g_drag && g_drag->live ? g_drag->insert : g_foreignInsert;
}

// Where the caret sits for an insertion index: hard against the left edge of
// the icon that would follow it, or past the last favourite when it is the end.
CBox caretBox(const SLayout& layout, int index, float scale) {
    const auto SLOTS = favoriteSlots(layout);
    if (index < 0 || SLOTS.empty())
        return {};

    const float W = std::max(2.F, std::round(3.F * scale));
    const auto& REF = layout.items[SLOTS[std::min(sc<size_t>(index), SLOTS.size() - 1)]].iconBox;
    const bool  END = sc<size_t>(index) >= SLOTS.size();

    const double X = END ? REF.x + REF.width + ITEM_MARGIN_X * scale - W / 2.0 : REF.x - ITEM_MARGIN_X * scale - W / 2.0;
    return CBox{X, REF.y, W, REF.height}.round();
}

}

bool pillContains(PHLMONITOR monitor, const Vector2D& point) {
    if (!monitor)
        return false;

    const auto PILL = layout(monitor).pill;
    return PILL.width >= 1 && PILL.height >= 1 && PILL.containsPoint(point);
}

bool scroll(PHLMONITOR monitor, const Vector2D& point, bool up) {
    if (!pillContains(monitor, point))
        return false;

    const auto ACTION = Config::getValue<std::string>(KEY_SCROLL_ACTION);
    if (ACTION != "cycle-windows" && ACTION != "switch-workspace")
        return true; // `do-nothing` still SWALLOWS: the pill is not a window.

    // The dead time is checked before the hit-test and after the action, so a
    // swallowed tick does not start the clock and `do-nothing` never does. One
    // clock for both actions, as in the reference -- they can never both be on.
    static Time::steady_tp s_last{};
    static bool            s_seen = false;

    if (s_seen && elapsedMs(s_last) < SCROLL_DEAD_MS)
        return true;

    s_last = Time::steadyNow();
    s_seen = true;

    if (ACTION == "switch-workspace") {
        // `activeWs.get_neighbor(direction)`: up is the PREVIOUS workspace, and
        // an edge is a no-op rather than a wrap -- get_neighbor hands back the
        // same workspace when there is nothing past it.
        const auto ACTIVE = monitor->m_activeWorkspace;
        if (!ACTIVE)
            return true;

        const WORKSPACEID WANTED = ACTIVE->m_id + (up ? -1 : 1);
        for (const auto& CANDIDATE : State::workspaceState()->workspaces()) {
            const auto TARGET = CANDIDATE.lock();
            if (TARGET && TARGET->m_id == WANTED && TARGET != ACTIVE) {
                monitor->changeWorkspace(TARGET, false, true, true);
                break;
            }
        }

        return true;
    }

    // `cycle-windows` is an ICON action: the reference binds it to the AppIcon,
    // so the pill's own background does nothing under this setting. It still
    // swallowed the tick above, which is the point of the pill.
    const auto LAYOUT = layout(monitor);
    const auto ITEM   = std::ranges::find_if(LAYOUT.items, [&](const SItem& item) { return hoverBox(item.iconBox, monitor->m_scale).containsPoint(point); });
    if (ITEM == LAYOUT.items.end())
        return true;

    cycleOrActivate(ITEM->wmClass, up);
    return true;
}

void showOverlay() {
    if (!Config::getValue<bool>(KEY_HOT_KEYS))
        return;

    // `_optionalNumberOverlay`: the extra shortcut is registered at all only
    // when one of the two is on, and each effect is gated again on its own key
    // inside `_showOverlay`. With both off this is a no-op, which is why the
    // deadline is not moved rather than moved and then ignored twice.
    if (!Config::getValue<bool>(KEY_HOTKEY_OVERLAY) && !Config::getValue<bool>(KEY_HOTKEY_DOCK))
        return;

    const float SECS = std::max(0.F, Config::getValue<float>(KEY_SHORTCUT_SECS));
    g_overlayUntil   = Time::steadyNow() + std::chrono::milliseconds(sc<int>(std::round(SECS * 1000.F)));

    // A keypress is not a frame, and render.pre only fires inside one, so the
    // first repaint has to be asked for here. Every monitor, because the
    // reference shows the numbers on every dock it has, not just the focused
    // one.
    for (const auto& MONITOR : State::monitorState()->monitors()) {
        if (MONITOR)
            damageIfChanged(MONITOR);
    }
}

void hotkey(int number, bool shift, bool ctrl) {
    if (!Config::getValue<bool>(KEY_HOT_KEYS))
        return;

    // `_showOverlay()` runs beside `_activateApp`, not after a successful one,
    // and `_activateApp` no-ops past the end of the dash. An empty slot
    // therefore still draws the numbers -- which is how you see it is empty.
    showOverlay();

    const auto MONITOR = Desktop::focusState()->monitor();
    if (!MONITOR)
        return;

    const auto LAYOUT = layout(MONITOR);
    const int  INDEX  = number - 1;
    if (INDEX < 0 || INDEX >= sc<int>(LAYOUT.items.size()))
        return;

    const auto& ITEM = LAYOUT.items[INDEX];

    // The three modifiers are three branches of ONE `AppIcon.activate(button=1)`
    // reading the KEY event's state, not three behaviours of their own -- which
    // is why the reference binds all thirty accelerators to one callback.
    // CONTROL short-circuits to GNOME's own activate (a new window of a running
    // app, a launch of a stopped one); SHIFT picks `shift-click-action`; neither
    // reaches `clickAction`.
    if (ctrl)
        launchApp(MONITOR, ITEM);
    else
        activateItem(MONITOR, ITEM, shift);
}

bool click(PHLMONITOR monitor, const Vector2D& point, bool shift, bool middle, bool ctrl) {
    if (!monitor)
        return false;

    const auto LAYOUT = layout(monitor);
    if (LAYOUT.pill.width < 1 || LAYOUT.pill.height < 1)
        return false;

    // X33. The middle button reaches ICONS only. A preview is one window and
    // "launch a new one" is not a thing to do to it, and Show Applications is a
    // button rather than an app -- the reference's middle-click lives on the
    // AppIcon and nowhere else.
    if (middle) {
        const auto ITEM =
            std::ranges::find_if(LAYOUT.items, [&](const SItem& item) { return hoverBox(item.iconBox, monitor->m_scale).containsPoint(point); });
        if (ITEM == LAYOUT.items.end())
            return false;

        applyClickAction(monitor, *ITEM, Config::getValue<std::string>(shift ? KEY_SHIFT_MIDDLE : KEY_MIDDLE_CLICK), shift);
        return true;
    }

    // A preview is one specific window, so it restores that window rather than
    // going through the class -- two minimized windows of one app are two
    // previews, and the class path could not tell them apart.
    for (const auto& PREVIEW : LAYOUT.previews) {
        if (PREVIEW.box.containsPoint(point)) {
            Minimize::restore(PREVIEW.window);
            return true;
        }
    }

    // X32 Show Applications. Ahead of the icons because its cell is laid out
    // like one and would otherwise have to be excluded from their search.
    if (!LAYOUT.showApps.empty() && hoverBox(LAYOUT.showApps, monitor->m_scale).containsPoint(point)) {
        // The app GRID this opens is G5's, and G5 is not built. What X32 owns is
        // the button: its slot, its edge, and the fact that it opens the surface
        // apps are searched from. So on the desktop it opens the overview; with
        // the overview already up there is nothing further to show yet, and it
        // deliberately does NOT toggle it shut -- a button that closes the thing
        // it is supposed to open would be worse than one that waits for G5.
        if (!scrollOverviewForMonitor(monitor))
            openScrollOverview(monitor);

        return true;
    }

    // Hit-test the same cell the hover highlight lights up, so what looks
    // clickable is what is clickable.
    const auto ITEM = std::ranges::find_if(LAYOUT.items, [&](const SItem& item) { return hoverBox(item.iconBox, monitor->m_scale).containsPoint(point); });
    if (ITEM == LAYOUT.items.end())
        return false;

    activateItem(monitor, *ITEM, shift, ctrl);
    return true;
}

int dropIndexAt(PHLMONITOR monitor, const Vector2D& point) {
    if (!monitor)
        return -1;

    const auto LAYOUT = layout(monitor);
    if (LAYOUT.pill.width < 1 || !LAYOUT.pill.containsPoint(point))
        return -1;

    const auto SLOTS = favoriteSlots(LAYOUT);
    for (size_t k = 0; k < SLOTS.size(); ++k) {
        // The MIDPOINT, not the edge. Dropping on an icon's left half puts the
        // dragged app before it; an edge test leaves a dead strip between icons
        // where the drop has no answer at all.
        const auto& BOX = LAYOUT.items[SLOTS[k]].iconBox;
        if (point.x < BOX.x + BOX.width / 2.0)
            return sc<int>(k);
    }

    return sc<int>(SLOTS.size());
}

bool showAppsContains(PHLMONITOR monitor, const Vector2D& point) {
    if (!monitor)
        return false;

    const auto LAYOUT = layout(monitor);
    return !LAYOUT.showApps.empty() && hoverBox(LAYOUT.showApps, monitor->m_scale).containsPoint(point);
}

void pinAt(const std::string& desktopId, int index) {
    if (desktopId.empty() || index < 0)
        return;

    auto& FAV = favorites();

    // Where the id sits TODAY, counted the way `index` is counted. Removing the
    // dragged icon shifts everything after it one place left, so a move to a
    // later slot would otherwise land one short of the caret the user saw.
    int from = -1;
    for (int seen = 0; const auto& ID : FAV) {
        if (!AppSearch::entryForId(ID))
            continue;
        if (ID == desktopId) {
            from = seen;
            break;
        }
        ++seen;
    }

    if (from >= 0) {
        std::erase(FAV, desktopId);
        if (from < index)
            --index;
    }

    // `index` counts DRAWN favourites, but the store also holds ids this machine
    // does not provide -- the seed is the user's HOST list. Walk the store to
    // find the position the index-th drawn favourite occupies, so the undrawn
    // ones keep their places instead of being silently reordered around.
    size_t at = FAV.size();
    for (size_t i = 0, seen = 0; i < FAV.size(); ++i) {
        if (!AppSearch::entryForId(FAV[i]))
            continue;
        if (seen == sc<size_t>(index)) {
            at = i;
            break;
        }
        ++seen;
    }

    FAV.insert(FAV.begin() + sc<long>(at), desktopId);
    writeFavorites();
}

void unpin(const std::string& desktopId) {
    if (desktopId.empty())
        return;

    if (std::erase(favorites(), desktopId) > 0)
        writeFavorites();
}

bool dragBegin(PHLMONITOR monitor, const Vector2D& point) {
    g_drag.reset();

    if (!monitor)
        return false;

    const auto LAYOUT = layout(monitor);
    const auto ITEM   = std::ranges::find_if(LAYOUT.items, [&](const SItem& item) { return hoverBox(item.iconBox, monitor->m_scale).containsPoint(point); });
    if (ITEM == LAYOUT.items.end() || ITEM->desktopId.empty())
        return false;

    g_drag = SDockDrag{.id = ITEM->desktopId, .start = point};
    return true;
}

bool dragMove(PHLMONITOR monitor, const Vector2D& point) {
    if (!g_drag || !monitor)
        return false;

    if (!g_drag->live) {
        const float T = dragThresholdPx(monitor);
        if (g_drag->start.distanceSq(point) <= T * T)
            return false;

        g_drag->live = true;
    }

    g_drag->insert = dropIndexAt(monitor, point);
    return true;
}

bool dragEnd(PHLMONITOR monitor, const Vector2D& point) {
    if (!g_drag)
        return false;

    const auto DRAG = *g_drag;
    g_drag.reset();

    if (!DRAG.live)
        return false;

    // USER-REPORTED P0 2026-08-06: "I cant use the dock clicking it does
    // nothing". This is X16's lesson arriving on the dock, and it is why the
    // scripted rig could not see it -- that rig jitters 4px, under the 10px
    // getDragThreshold, so it never went down this path at all.
    //
    // A drag goes live the moment the pointer passes that threshold, and a real
    // hand wobbles 10-20px between press and release. The release then landed
    // HERE, reordered the favourite, and returned true -- which swallowed the
    // click, so the app never minimized or launched. To the user that is a dead
    // dock, and Y4 made it worse by making the click the primary gesture.
    //
    // A release that lands near where the press did is a CLICK, whatever the
    // pointer did in between. Same 3x tolerance X16 settled on for window tiles.
    const float CLICKTOL = 3.F * dragThresholdPx(monitor);
    if (DRAG.start.distanceSq(point) <= CLICKTOL * CLICKTOL)
        return false;

    // A drop that leaves the pill is a CANCEL, not an unpin. Losing a favourite
    // to a slipped gesture is not a thing to offer, and X26 already owns
    // dragging in the other direction.
    const int INDEX = dropIndexAt(monitor, point);
    if (INDEX < 0)
        return false;

    pinAt(DRAG.id, INDEX);
    return true;
}

void dragCancel() {
    g_drag.reset();
}

bool dragPending() {
    return g_drag.has_value();
}

bool dragging() {
    return g_drag && g_drag->live;
}

void setForeignInsert(int index) {
    g_foreignInsert = index;
}

bool openMenu(PHLMONITOR monitor, const Vector2D& point) {
    closeMenu();

    if (!monitor)
        return false;

    const auto LAYOUT = layout(monitor);
    if (LAYOUT.pill.empty())
        return false;

    // The same cell the hover highlight and the left-click use, so the three
    // gestures cannot disagree about which icon is under the pointer.
    const auto ITEM = std::ranges::find_if(LAYOUT.items, [&](const SItem& item) { return hoverBox(item.iconBox, monitor->m_scale).containsPoint(point); });
    if (ITEM == LAYOUT.items.end())
        return false;

    g_menu = SMenu{.monitor = monitor->m_id, .item = *ITEM, .anchor = ITEM->iconBox, .box = {}, .rows = buildRows(*ITEM)};
    return true;
}

bool menuOpen() {
    return g_menu.has_value();
}

void closeMenu() {
    g_menu.reset();
}

bool menuContains(PHLMONITOR monitor, const Vector2D& point) {
    return g_menu && monitor && g_menu->monitor == monitor->m_id && !g_menu->box.empty() && g_menu->box.containsPoint(point);
}

bool menuClick(PHLMONITOR monitor, const Vector2D& point) {
    if (!menuContains(monitor, point))
        return false;

    const auto ROW = std::ranges::find_if(g_menu->rows, [&](const SRow& row) { return row.kind != ERow::Separator && !row.box.empty() && row.box.containsPoint(point); });
    if (ROW == g_menu->rows.end())
        return false; // the plate, between rows: swallowed by the caller, menu stays up

    // Copied before the menu goes away: activating a row can close the overview,
    // and g_menu must not be read through after that.
    const auto ITEM = g_menu->item;
    const auto PICK = *ROW;
    closeMenu();

    activateRow(monitor, ITEM, PICK);
    return true;
}

bool damageIfChanged(PHLMONITOR monitor) {
    if (!monitor)
        return false;

    // X31. The bus connection is opened by the first frame that could use it, so
    // a dock switched off -- or one with both badge and urgent-notify off --
    // never opens one at all. Idempotent.
    if (Config::getValue<bool>(KEY_ENABLED) && (Config::getValue<bool>(KEY_BADGE) || Config::getValue<bool>(KEY_URGENT_NOTIFY)))
        LauncherEntry::start();

    updateAutohide(monitor);

    // X30. A flip waiting out its delay looks EXACTLY like the frame before it,
    // so the signature check below would stop the chain of frames dead and the
    // dock would freeze half-way -- or never start. render.pre only fires when a
    // frame is already happening, so the next one has to be asked for here, and
    // after the current frame (doLater) for the same reason the live previews
    // are: damage asked for during the pass is cleared with the pass.
    // X31's wiggle is in here for the same reason: its rotation changes every
    // frame while it runs, and nothing else on an idle desktop asks for one.
    //
    // ponytail: this pumps frames for the 2500ms of every 3000ms the urgent icon
    // is deliberately STILL, as well as the 500 it moves. Waking on a timer for
    // the next burst instead would save them; measure it before building it.
    // One layout, used by both the wiggle test and the signature below.
    // layout() rebuilds the whole item model -- a scan of every window, a set of
    // running classes, and a fresh vector of SItems carrying several strings
    // each -- and this function runs on every frame AND on every pointer motion
    // event, which arrive far faster than frames do. It was being built twice.
    const auto LAYOUT = layout(monitor);

    const bool WIGGLING = Config::getValue<bool>(KEY_DANCE_URGENT) && anyUrgent(LAYOUT.items);

    if (autohideAnimating(monitor) || WIGGLING || overlayUp())
        g_pEventLoopManager->doLater([MONITOR = PHLMONITORREF{monitor}] {
            if (MONITOR)
                g_pHyprRenderer->damageMonitor(MONITOR.lock());
        });

    std::string signature;
    if (!LAYOUT.pill.empty()) {
        // pill.y is in the signature because during the slide it is the ONLY
        // thing that changes.
        signature = std::to_string(sc<int>(LAYOUT.pill.x)) + "," + std::to_string(sc<int>(LAYOUT.pill.y)) + "," + std::to_string(sc<int>(LAYOUT.pill.width));
        for (const auto& ITEM : LAYOUT.items) {
            // X32. The desktop id is in here as well as the class because a
            // pinned favourite HAS no class: without it, launching a pinned app
            // -- or pinning one while another is already pinned -- leaves the
            // signature identical and the dot never appears.
            // X35. The icon NAME, because the trash swaps `user-trash` for
            // `user-trash-full` without moving a box. Ceiling: the swap is seen
            // when the poll next runs AND something asks for a frame, so on a
            // wholly idle desktop the new icon can lag the deletion by a beat.
            signature += "|" + ITEM.desktopId + "/" + ITEM.wmClass + ITEM.uri + ITEM.icon + (ITEM.running ? "+" : "-");

            // A location has no class, so every badge lookup below would key on
            // the empty string -- and a location has no notifications anyway.
            if (!ITEM.running || !ITEM.uri.empty())
                continue;

            // X31. A badge arriving, or an app going urgent, changes what the
            // pill LOOKS like without moving a single box -- so the signature
            // has to carry them or the first frame that would show either one
            // never gets asked for.
            if (const auto COUNT = badgeCount(ITEM.wmClass); COUNT > 0)
                signature += "!" + std::to_string(COUNT);
            if (classUrgent(ITEM.wmClass))
                signature += "*";
        }

        // The hovered cell is part of what the pill LOOKS like, so a bare pointer
        // move over an otherwise idle dock has to repaint it -- nothing else on
        // the desktop damages the monitor for a motion event.
        const auto MOUSE = (g_pInputManager->getMouseCoordsInternal() - monitor->m_position) * monitor->m_scale;
        for (size_t i = 0; i < LAYOUT.items.size(); ++i) {
            if (hoverBox(LAYOUT.items[i].iconBox, monitor->m_scale).containsPoint(MOUSE)) {
                signature += "#" + std::to_string(i);
                break;
            }
        }

        if (!LAYOUT.showApps.empty() && hoverBox(LAYOUT.showApps, monitor->m_scale).containsPoint(MOUSE))
            signature += "#apps";

        // X32/G12. The insertion caret moves on a bare pointer move exactly as
        // the hover highlight does, and nothing else on the desktop asks for a
        // frame during a drag.
        if (const int CARET = caretIndex(); CARET >= 0)
            signature += "^" + std::to_string(CARET);

        // X34. Same reasoning as the badge: the numbers arrive and leave
        // without a single box moving, so they have to be in here or the frame
        // that draws them -- and the one that clears them -- is never asked for.
        if (overlayUp())
            signature += "~overlay";

        // X28. The menu is part of what the dock looks like, and its hovered row
        // moves with a bare pointer move exactly as the icon highlight does.
        if (g_menu && g_menu->monitor == monitor->m_id) {
            signature += "@" + g_menu->item.wmClass + g_menu->item.uri;
            for (size_t i = 0; i < g_menu->rows.size(); ++i) {
                if (!g_menu->rows[i].box.empty() && g_menu->rows[i].box.containsPoint(MOUSE)) {
                    signature += "/" + std::to_string(i);
                    break;
                }
            }
        }
    }

    auto& LAST = g_signatures[monitor->m_id];
    if (LAST == signature)
        return false;

    LAST = signature;
    g_pHyprRenderer->damageMonitor(monitor);
    return true;
}

// X54. The PUBLIC way to minimize or restore. Everything must come through
// these: onMinimizeDispatcher called Minimize::minimize straight through, so a
// keybind-driven minimize never armed a flight at all -- which is why every rig
// pointed at the dispatcher measured "no animation", and why the diagnostic log
// came back EMPTY rather than wrong.
void setWindowDragActive(bool active) {
    g_windowDragActive = active;
}

void minimizeWithFlight(PHLMONITOR monitor, PHLWINDOW window, bool bounceOnLand) {
    minimizeWithFlightImpl(monitor, window, bounceOnLand);
}

void restoreWithFlight(PHLMONITOR monitor, PHLWINDOW window) {
    restoreWithFlightImpl(monitor, window);
}


namespace {

// OVERVIEW_CPP_SPEC 13.12 X47. HOVER RAISES A LIVE PREVIEW.
//
// The previews are REAL, LIVE, compositor-rendered windows -- X25's requirement
// carried over unchanged into this new home. What X47 changes is WHEN they are
// drawn: hover, rather than a permanent slot in the pill (which X46 deleted).
// That is also what makes this cheaper than the inline previews it replaces --
// 13.9's live-on-demand constraint says a window nobody renders gets no frame
// callbacks, and hover is the natural on-demand signal.
//
// X25's drawing path, lifted out of render()'s lambda so the panel can use it
// too. Force visibility for anything NOT currently shown on this monitor's
// active desktop: minimized (special stash workspace) AND windows on other
// workspaces. On-screen active-desktop windows need none of it — asserting
// their alpha would stomp compositor animations. X99: other-desktop previews
// went blank after X91 because only minimized was forced.
// Y5. `alpha` is the flight's fade. It is applied AFTER forcePreviewVisible,
// which warps the window's alpha to 1 as part of making a stashed window
// drawable at all -- setting it before would simply be overwritten.
// `asOverviewTile` picks WHICH real-window path this draws through, and it
// matters more than it looks. Both render the ACTUAL window -- neither is a
// screenshot -- but the dock path (X91) early-returns after a scale+translate
// modif, BEFORE the block that scales blur to the render scale and forces LIVE
// blur. That is right for a 130px thumbnail and wrong for the flight, which is
// a full-size window shrinking across the screen: on the dock path its frost is
// neither scaled nor live, so it carries stale blur for the whole animation.
// The flight therefore goes through the OVERVIEW path, exactly as a tile does.
// Y11. Every window the dock has drawn a live preview of recently, so the
// OVERVIEW can be told not to starve it of frame callbacks.
//
// Time-stamped rather than cleared on a frame boundary: render() runs once per
// monitor and the compositor's frame-event pass can fall on either side of it,
// so a set that was emptied at the top of one monitor's render would answer
// "no" for windows the other monitor is previewing. A window drawn within
// PREVIEWING_MS is being previewed; nothing else has to be true.
constexpr float                                            PREVIEWING_MS = 250.F;
std::vector<std::pair<PHLWINDOWREF, Time::steady_tp>>      g_previewed;

// REAL milliseconds, deliberately NOT the dock's elapsedMs. That one divides by
// plugin:scrolloverview:anim_scale, which is right for every animation in this
// file and wrong here: this is a staleness window on a frame-callback policy,
// not a curve. At anim_scale 10 it would hold entries for 2.5s, and at 0.05 it
// would expire them in 12ms and starve the previews it exists to keep alive.
float realElapsedMs(const Time::steady_tp& since) {
    return sc<float>(std::chrono::duration<float, std::milli>(Time::steadyNow() - since).count());
}

void notePreviewing(const PHLWINDOW& window) {
    const auto NOW = Time::steadyNow();
    std::erase_if(g_previewed, [&](const auto& e) { return !e.first.lock() || realElapsedMs(e.second) >= PREVIEWING_MS; });

    for (auto& [REF, AT] : g_previewed) {
        if (REF.lock() == window) {
            AT = NOW;
            return;
        }
    }

    g_previewed.emplace_back(PHLWINDOWREF{window}, NOW);
}

void renderLivePreview(PHLMONITOR monitor, const PHLWINDOW& window, const CBox& box, const Time::steady_tp& now, float alpha = 1.F, bool asOverviewTile = false,
                       bool ownsRenderPass = true) {
    notePreviewing(window);

    const bool STASHED = Minimize::isMinimized(window);
    const bool OFF_ACTIVE =
        !window->m_workspace || !monitor || window->m_workspace != monitor->m_activeWorkspace;
    // Minimized always; otherwise any window not on this monitor's active ws.
    const bool NEED_FORCE = STASHED || OFF_ACTIVE;

    bool       wasWsVisible = false;
    bool       wasWsForce   = false;
    PHLWORKSPACE ws;
    if (NEED_FORCE) {
        forcePreviewVisible(window);
        ws = window->m_workspace;
        if (ws) {
            wasWsVisible         = ws->m_visible;
            wasWsForce           = ws->m_forceRendering;
            ws->m_visible        = true;
            ws->m_forceRendering = true;
        }
    }

    const auto  SIZE        = window->m_realSize->value();
    const float RENDERSCALE = SIZE.y >= 1.0 ? sc<float>(box.height / (SIZE.y * monitor->m_scale)) : 1.F;

    OverviewWindow::renderOverviewWindow({
        .monitor                 = monitor,
        .window                  = window,
        .windowBox               = box,
        .renderScale             = RENDERSCALE,
        .now                     = now,
        // X90: dock THUMBNAILS must not touch decoration:blur:size / m_blurFB.
        // The flight is not a thumbnail and takes the overview path instead, so
        // its blur scales and stays live like every other real window.
        .scaleBlurToRenderScale  = asOverviewTile,
        // X91: do not rewrite real window geometry (ghost mini outline).
        .dockLivePreview         = !asOverviewTile,
        .alpha                   = alpha,
        .ownsRenderPass          = ownsRenderPass,
    });

    if (ws) {
        ws->m_visible        = wasWsVisible;
        ws->m_forceRendering = wasWsForce;
    }

    // Frame callbacks for anything that would otherwise freeze (hidden ws).
    if (NEED_FORCE)
        presentPreview(window, monitor, now);
}

// The panel GROWS OUT OF THE ICON rather than fading in on the spot -- the same
// trick X54's flight uses, and it is why this needs no alpha on the window
// content: renderOverviewWindow has no alpha parameter, but it scales, so the
// entrance is a box lerp and the previews ride it.
struct SPanel {
    std::string     wmClass;
    CBox            anchor;                          // the icon it belongs to
    CBox            target;                          // where it settles
    CBox            from;                            // where the current move started
    Time::steady_tp moveSince = Time::steadyNow();
    float           moveMs    = PANEL_IN_MS;
    bool            decel     = true;                // entrances decelerate, exits do not
    bool            out       = false;
    bool            leaving   = false;               // inside the grace period
    Time::steady_tp leftAt    = Time::steadyNow();
};

std::optional<SPanel> g_panel;

void dismissHoverPanelNow() {
    g_panel.reset();
    // The tooltip is a separate element and lingered into the flight ("sh"
    // bubble, frame 279 of the verification film). Clearing the name kills it
    // this frame -- the fade-out path only runs while a name is remembered.
    g_tip = {};
}

// Y1/Y2. The panel AS DRAWN last frame, plus the cell each window landed in.
// Hit-testing has to use these rather than the settled target: during the
// entrance and the slide the plate on screen is somewhere else entirely, and a
// pointer resting on what it can see must not fall through a box that has not
// arrived yet. Same reasoning the X28 menu already documents for its rows.
CBox                                       g_panelDrawn;
std::vector<std::pair<CBox, PHLWINDOWREF>> g_panelCells;

void forgetPanelGeometry() {
    g_panelDrawn = CBox{};
    g_panelCells.clear();
}

// Y1. Inside the plate that is actually on screen -- and not while it is
// leaving, or a dismissal already under way would be resurrected by a pointer
// that merely happens to be where the shrinking plate still is.
bool panelContains(const Vector2D& point) {
    return g_panel && !g_panel->out && g_panelDrawn.width >= 1 && g_panelDrawn.height >= 1 && g_panelDrawn.containsPoint(point);
}

// Y2. The preview cell under the pointer and the window in it. The BOX comes
// back with the window because the title plate is centred on the cell, not on
// the icon the panel belongs to.
std::optional<std::pair<CBox, PHLWINDOW>> panelCellAt(const Vector2D& point) {
    for (const auto& [BOX, REF] : g_panelCells) {
        if (!BOX.containsPoint(point))
            continue;

        if (const auto WINDOW = REF.lock(); WINDOW)
            return std::make_pair(BOX, WINDOW);
    }

    return std::nullopt;
}

bool sameBox(const CBox& a, const CBox& b) {
    return sc<int>(a.x) == sc<int>(b.x) && sc<int>(a.y) == sc<int>(b.y) && sc<int>(a.width) == sc<int>(b.width) && sc<int>(a.height) == sc<int>(b.height);
}

// The windows an icon previews. classWindows already answers with the minimized
// ones included, which is what makes a minimized window reachable from its own
// icon -- the whole point of X45's 1-window branch.
std::vector<PHLWINDOW> panelWindows(const std::string& wmClass) {
    if (wmClass.empty())
        return {};

    auto out = classWindows(wmClass);
    std::erase_if(out, [](const auto& window) { return !window || !window->m_isMapped || !window->wlSurface() || !window->wlSurface()->resource(); });
    if (out.size() > PANEL_MAX)
        out.resize(PANEL_MAX);

    return out;
}

// One cell per window, side by side, each keeping its window's aspect.
CBox panelTarget(PHLMONITOR monitor, const SLayout& layout, const std::vector<PHLWINDOW>& windows, const CBox& anchor) {
    const float SCALE = std::max(monitor->m_scale, 0.01F);
    const float CELLH = PANEL_CELL_H * SCALE;

    float content = 0.F;
    for (size_t i = 0; i < windows.size(); ++i)
        content += CELLH * previewAspect(windows[i]) + (i ? PANEL_CELL_GAP * SCALE : 0.F);

    const float WIDTH  = std::round(content + 2.F * PANEL_PAD * SCALE);
    const float HEIGHT = std::round(CELLH + 2.F * PANEL_PAD * SCALE);
    const float CX     = sc<float>(anchor.x) + sc<float>(anchor.width) / 2.F;

    // Clamped to the monitor: an icon near either end would otherwise push half
    // the panel off screen, which is where a taskbar preview stops being one.
    const float MARGIN = PANEL_PAD * SCALE;
    const float MAXX   = sc<float>(monitor->m_size.x) * SCALE - WIDTH - MARGIN;
    const float X      = std::clamp(CX - WIDTH / 2.F, MARGIN, std::max(MARGIN, MAXX));

    return CBox{std::round(X), std::round(sc<float>(layout.pill.y) - PANEL_GAP * SCALE - HEIGHT), WIDTH, HEIGHT};
}

// Pass an empty class when nothing is hovered; like the tooltip, the panel
// outlives the hover so that it can animate AWAY instead of blinking out.
void renderHoverPreview(PHLMONITOR monitor, const SLayout& layout, const CBox& anchor, const std::string& wmClass, const Time::steady_tp& now) {
    auto       windows = panelWindows(wmClass);
    const bool WANT    = !windows.empty();

    if (WANT) {
        const CBox TARGET = panelTarget(monitor, layout, windows, anchor);

        if (!g_panel) {
            // Rises out of the icon, decelerating into place.
            g_panel = SPanel{.wmClass = wmClass, .anchor = anchor, .target = TARGET, .from = anchor, .moveSince = now, .moveMs = PANEL_IN_MS, .decel = true};
        } else {
            g_panel->leaving = false;
            g_panel->wmClass = wmClass;
            g_panel->anchor  = anchor;

            // Caught mid-dismissal, or moved to another icon: in both cases the
            // move restarts from WHERE IT IS, which is what makes it read as one
            // panel following the pointer rather than two panels swapping.
            if (g_panel->out || !sameBox(g_panel->target, TARGET)) {
                const float T = std::clamp(elapsedMs(g_panel->moveSince) / std::max(1.F, g_panel->moveMs), 0.F, 1.F);

                g_panel->from      = lerpBox(g_panel->from, g_panel->target, houseEase(g_panel->decel, T));
                g_panel->target    = TARGET;
                g_panel->moveSince = now;
                g_panel->moveMs    = g_panel->out ? PANEL_IN_MS : PANEL_SLIDE_MS;
                g_panel->decel     = true;
                g_panel->out       = false;
            }
        }
    } else if (g_panel) {
        if (!g_panel->out && !g_panel->leaving) {
            g_panel->leaving = true;
            g_panel->leftAt  = now;
        }

        // The grace expires: shrink back into the icon, accelerating.
        if (g_panel->leaving && elapsedMs(g_panel->leftAt) >= PANEL_GRACE_MS) {
            const float T = std::clamp(elapsedMs(g_panel->moveSince) / std::max(1.F, g_panel->moveMs), 0.F, 1.F);

            g_panel->from      = lerpBox(g_panel->from, g_panel->target, houseEase(g_panel->decel, T));
            g_panel->target    = g_panel->anchor;
            g_panel->moveSince = now;
            g_panel->moveMs    = PANEL_OUT_MS;
            g_panel->decel     = false;
            g_panel->out       = true;
            g_panel->leaving   = false;
        }

        // The panel keeps drawing the LAST app's windows while it dismisses --
        // the pointer has already left, so nothing else names them.
        windows = panelWindows(g_panel->wmClass);
        if (windows.empty()) {
            g_panel.reset();
            forgetPanelGeometry();
            return;
        }
    } else {
        forgetPanelGeometry();
        return;
    }

    const float T = std::clamp(elapsedMs(g_panel->moveSince) / std::max(1.F, g_panel->moveMs), 0.F, 1.F);
    if (g_panel->out && T >= 1.F) {
        g_panel.reset();
        forgetPanelGeometry();
        return;
    }

    const CBox  DRAWN = lerpBox(g_panel->from, g_panel->target, houseEase(g_panel->decel, T));
    const float SCALE = std::max(monitor->m_scale, 0.01F);

    if (DRAWN.width < 2.0 || DRAWN.height < 2.0) {
        forgetPanelGeometry();
        return;
    }

    // The plate fades with the growth so the frost does not slam on at full
    // strength over the icon it is still the size of.
    const float ALPHA   = g_panel->out ? 1.F - houseEase(false, T) : houseEase(true, T);
    const int   ROUNDED = sc<int>(std::round(PANEL_RADIUS * SCALE));

    // X13/X29/X86: panel frost shares overview chrome blur when Super is open.
    queueDockFrost(monitor, DRAWN, ROUNDED, ALPHA);

    auto                        colour = background();
    CRectPassElement::SRectData bg;
    bg.box           = DRAWN;
    bg.color         = CHyprColor{colour.r, colour.g, colour.b, colour.a * ALPHA};
    bg.round         = ROUNDED;
    bg.roundingPower = 2.F;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(bg));

    // Cells are laid out inside the box that is actually on screen this frame,
    // not inside the settled one -- otherwise the contents would overflow the
    // plate for the whole of the entrance.
    const float PAD   = PANEL_PAD * SCALE;
    const float CELLH = sc<float>(DRAWN.height) - 2.F * PAD;
    const float GAPS  = PANEL_CELL_GAP * SCALE * sc<float>(windows.size() - 1);
    const float AVAIL = sc<float>(DRAWN.width) - 2.F * PAD - GAPS;
    if (CELLH < 1.F || AVAIL < 1.F) {
        forgetPanelGeometry();
        return;
    }

    float sum = 0.F;
    for (const auto& WINDOW : windows)
        sum += previewAspect(WINDOW);

    // Y1/Y2. Published for the pointer, which is why it is the DRAWN plate and
    // the DRAWN cells rather than the settled ones.
    g_panelDrawn = DRAWN;
    g_panelCells.clear();
    g_panelCells.reserve(windows.size());

    float x = sc<float>(DRAWN.x) + PAD;
    for (const auto& WINDOW : windows) {
        const float WIDTH = AVAIL * previewAspect(WINDOW) / std::max(sum, 0.01F);

        CBox cell{std::round(x), std::round(sc<float>(DRAWN.y) + PAD), std::round(WIDTH), std::round(CELLH)};
        renderLivePreview(monitor, WINDOW, cell, now);
        g_panelCells.emplace_back(cell, PHLWINDOWREF{WINDOW});

        x += WIDTH + PANEL_CELL_GAP * SCALE;
    }
}

// Y1. The autohide's question, answered against the plate on screen. Declared
// far above, beside updateAutohide, which runs long before any of this is in
// scope.
bool panelHoldsDock(PHLMONITOR monitor) {
    if (!monitor || !g_panel)
        return false;

    return panelContains((g_pInputManager->getMouseCoordsInternal() - monitor->m_position) * monitor->m_scale);
}

// Whether anything of the panel is on screen. render()'s damage loop asks: a
// pointer resting on an icon emits no motion, so without a frame of its own the
// entrance would freeze on its first step and the previews would be stills.
bool panelUp() {
    return g_panel.has_value();
}

}

// Z2. A CLICK on a preview goes to that window. The panel floats ABOVE the pill,
// so every one of these clicks failed the `pillContains` gate both button hooks
// open with and fell through to whatever window was underneath -- the panel was
// readable and dead, which is Y1's bug one layer up. Y2 already hit-tests these
// same cells for the title, so the geometry is there; only the button was
// missing. `release` because the dock's own gesture is press-remembers /
// release-decides, and a preview must not be the one place a press acts.
//
// Claiming the press as well is what stops it starting an icon drag or reaching
// the tile below; the caller swallows either edge on a true.
//
// OUTSIDE the anonymous namespace above, and that is not a style point: put in
// it, this compiles and links, and then Hyprland dies with `undefined symbol`
// the first time a mouse button is pressed -- a plugin's unresolved symbol is
// not a load-time error, it is a lazy-binding abort at the first call, so it
// took the compositor down mid-session rather than failing the build.
// Y11. Asked by CScrollOverview::shouldAllowSurfaceFrame. See the comment there
// for why a preview cannot keep itself alive without it.
bool isPreviewing(const PHLWINDOW& window) {
    if (!window)
        return false;

    return std::ranges::any_of(g_previewed, [&](const auto& e) { return e.first.lock() == window && realElapsedMs(e.second) < PREVIEWING_MS; });
}

bool panelClick(PHLMONITOR monitor, const Vector2D& point, bool release) {
    if (!monitor || !panelContains(point))
        return false;

    if (!release)
        return true;

    const auto CELL = panelCellAt(point);
    if (!CELL)
        return true;

    const auto WINDOW = CELL->second;

    // The SAME three lines the X28 menu's window rows already run, deliberately:
    // both are "the dock naming one window and being asked to go to it", and one
    // dock must not have two answers. So a minimized window is restored (the
    // stash has no card to land a selection on), and inside the overview the
    // window is committed as the selection AND the overview closes, which is
    // what a tile click does -- focusing it directly would be overwritten by
    // close()'s own selection.
    if (Minimize::isMinimized(WINDOW)) {
        Minimize::restore(WINDOW);
        return true;
    }

    if (const auto OVERVIEW = scrollOverviewForMonitor(monitor); OVERVIEW)
        OVERVIEW->selectAndClose(WINDOW);
    else
        activateWindow(WINDOW);

    return true;
}

// Y8. How far this app's icon is lifted out of the pill right now. Reads the
// largest of any overlapping hops rather than summing them, so two windows
// landing together is one bounce and not a double-height launch.
float bounceLift(const std::string& wmClass, float iconHeight) {
    float lift = 0.F;
    for (const auto& BOUNCE : g_bounces) {
        if (BOUNCE.wmClass != wmClass)
            continue;

        lift = std::max(lift, bounceCurve(std::clamp(elapsedMs(BOUNCE.startedAt) / BOUNCE_MS, 0.F, 1.F)) * BOUNCE_HEIGHT * iconHeight);
    }

    return lift;
}

// Y7. Zero at the top of the bottom-30% band and one at the pill, continuous
// between. Uses the pill as laid out THIS frame, so a dock still sliding out
// glows against where it actually is rather than where it will settle.
float dragGlow(PHLMONITOR monitor, const SLayout& layout, const Vector2D& mouse) {
    if (!g_windowDragActive || layout.pill.empty())
        return 0.F;

    const float H       = sc<float>(monitor->m_size.y) * monitor->m_scale;
    const float BANDTOP = H * (1.F - DRAG_GLOW_BAND);
    const float PILLTOP = sc<float>(layout.pill.y);

    if (sc<float>(mouse.y) <= BANDTOP || PILLTOP <= BANDTOP)
        return 0.F;

    return std::clamp((sc<float>(mouse.y) - BANDTOP) / (PILLTOP - BANDTOP), 0.F, 1.F);
}

void render(PHLMONITOR monitor) {
    // Y6/Y8. Retire what has run its course before anything asks whether the
    // dock still needs frames.
    std::erase_if(g_bounces, [](const SBounce& b) { return elapsedMs(b.startedAt) >= BOUNCE_MS; });
    std::erase_if(g_launchZooms, [](const SLaunchZoom& z) { return elapsedMs(z.startedAt) >= LAUNCH_ZOOM_MS; });

    const auto LAYOUT = layout(monitor);
    if (LAYOUT.pill.empty())
        return;

    const auto MOUSELOCAL = (g_pInputManager->getMouseCoordsInternal() - monitor->m_position) * monitor->m_scale;

    // Y7. Drawn FIRST so the pill's own frost and background land on top of it
    // and the halo only shows where it reaches past the pill's edges.
    if (const float GLOW = dragGlow(monitor, LAYOUT, MOUSELOCAL); GLOW > 0.001F) {
        const auto ACCENT = ScrollOverview::Config::highlightColor();

        // A stack of expanded rounded rects with a falling alpha. There is no
        // soft-shadow primitive to hand, and a real blur for a halo would be a
        // third full-monitor kawase every frame of a drag; three rings read as a
        // glow and cost three rects.
        // ponytail: swap for a proper falloff if this ever looks banded.
        constexpr int RINGS = 3;
        for (int i = RINGS; i >= 1; --i) {
            const float SPREAD = DRAG_GLOW_PX * monitor->m_scale * sc<float>(i) / sc<float>(RINGS);

            CRectPassElement::SRectData ring;
            ring.box           = LAYOUT.pill.copy().expand(SPREAD);
            ring.color         = ACCENT.modifyA(GLOW * DRAG_GLOW_ALPHA / sc<float>(i * i));
            ring.round         = LAYOUT.rounding + sc<int>(std::round(SPREAD));
            ring.roundingPower = 2.F;
            g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(ring));
        }
    }

    // X13/X29/X86: dock pill. Live on the desktop (single surface). In overview
    // it samples the same decoration:blur:* behind-chrome buffer as the strip
    // so strength cannot drift with search-result count.
    queueDockFrost(monitor, LAYOUT.pill, LAYOUT.rounding, 1.F);

    CRectPassElement::SRectData bg;
    bg.box           = LAYOUT.pill;
    bg.color         = background();
    bg.round         = LAYOUT.rounding;
    bg.roundingPower = 2.F;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(bg));

    // (user, 2026-08-03): GNOME lights the hovered app cell with a translucent
    // lighter fill and a slightly stronger outline, and labels it. Mouse coords
    // are global logical; the layout is monitor-local RENDER px.
    const auto& MOUSE      = MOUSELOCAL; // Y7 already resolved it, above the pill
    const auto HOVEREDITEM = std::ranges::find_if(LAYOUT.items, [&](const SItem& item) { return hoverBox(item.iconBox, monitor->m_scale).containsPoint(MOUSE); });
    const bool HASHOVER    = HOVEREDITEM != LAYOUT.items.end();

    // X32. The button's cell lights up like any other, so it reads as clickable
    // rather than as decoration.
    const bool HOVERAPPS = !LAYOUT.showApps.empty() && hoverBox(LAYOUT.showApps, monitor->m_scale).containsPoint(MOUSE);

    if (HASHOVER || HOVERAPPS) {
        // (user, 2026-08-03) A flat fill, no outline. The radius is CONCENTRIC
        // with the pill rather than a constant: the cell is inset from the pill
        // by the same amount on every side, so its curve only reads as parallel
        // to the dock's if the radius drops by that inset too.
        // X56 (user, 2026-08-06): themed, so the dock re-colours with
        // everything else when the Hyprland theme changes. The alpha is the
        // tuned value and stays -- only the hue comes from the config.
        const auto ACCENT = ScrollOverview::Config::highlightColor();

        CRectPassElement::SRectData fill;
        fill.box           = hoverBox(HASHOVER ? HOVEREDITEM->iconBox : LAYOUT.showApps, monitor->m_scale);
        fill.color         = ACCENT.modifyA(0.22F);
        fill.round         = std::max(0, LAYOUT.rounding - sc<int>(std::round(hoverInset() * monitor->m_scale)));
        fill.roundingPower = 2.F;
        g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(fill));
    }

    // X32/G12. Where the dragged app would land. Drawn under the icons so a
    // caret at the very first slot is not sitting on top of one.
    if (const CBox CARET = caretBox(LAYOUT, caretIndex(), monitor->m_scale); !CARET.empty()) {
        CRectPassElement::SRectData caret;
        caret.box           = CARET;
        caret.color         = CHyprColor{1.F, 1.F, 1.F, 0.90F};
        caret.round         = sc<int>(std::round(CARET.width / 2.F));
        caret.roundingPower = 2.F;
        g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(caret));
    }

    for (const auto& ITEM : LAYOUT.items) {
        if (const auto TEX = OverviewRender::appIcon(ITEM.icon); TEX) {
            CTexPassElement::SRenderData data;
            data.tex = TEX;
            data.box = ITEM.iconBox;

            // Y8. The ICON leaves the pill, the running dot and the badge stay
            // where they are -- which is what macOS does and what keeps the hop
            // from reading as the whole cell coming loose.
            data.box.y -= bounceLift(ITEM.wmClass, sc<float>(ITEM.iconBox.height));

            // X31 `dance-urgent-applications`. CBox::rot is radians about the
            // box's own centre, which is the reference's pivot (0.5, 0.5) --
            // so the wiggle is one assignment, not a transform stack.
            if (ITEM.running && ITEM.uri.empty() && Config::getValue<bool>(KEY_DANCE_URGENT) && classUrgent(ITEM.wmClass))
                data.box.rot = wiggleRadians();

            data.a = 1.F;
            g_pHyprRenderer->m_renderPass.add(makeUnique<CTexPassElement>(data));
        }

        // Both of these are deliberately OUTSIDE the texture check: an app with
        // no desktop entry still runs and can still have a count, and losing its
        // indicators as well as its icon would hide it twice over.
        //
        // X32 gates them on RUNNING: a pinned favourite with no window is the
        // one icon in the pill that must NOT get a dot, and that absence is the
        // only thing distinguishing it from the app next to it.
        if (ITEM.running) {
            if (Config::getValue<bool>(KEY_SHOW_RUNNING))
                renderRunningDot(monitor, LAYOUT, ITEM);

            renderBadge(monitor, ITEM);
        }

        // X34. Over the badge and the dot, because it is transient and it is the
        // thing being read for as long as it is up. OUTSIDE the running gate:
        // a pinned app that is not running still has a key.
        renderNumberOverlay(monitor, ITEM, sc<int>(&ITEM - LAYOUT.items.data()));
    }

    // X32 Show Applications, drawn last of the icon row so its cell is complete
    // before the plates go over the top.
    if (!LAYOUT.showApps.empty()) {
        // User, 2026-08-06: "make the Show Applications icon white, it's too
        // dark". view-app-grid-symbolic is near-black artwork sitting on a dark
        // frosted pill; every other icon in the dock is a full-colour app icon,
        // so this is the only one that needed it.
        if (const auto TEX = OverviewRender::appIcon(Config::getValue<std::string>(KEY_SHOW_APPS_ICON), true); TEX) {
            CTexPassElement::SRenderData data;
            data.tex = TEX;
            data.box = LAYOUT.showApps;
            data.a   = 1.F;
            g_pHyprRenderer->m_renderPass.add(makeUnique<CTexPassElement>(data));
        }
    }

    // Y6. GNOME's launch blow-up, drawn over the icon row so the growing clone
    // is not clipped by the neighbours it passes over.
    for (const auto& ZOOM : g_launchZooms) {
        const auto TEX = OverviewRender::appIcon(ZOOM.icon);
        if (!TEX)
            continue;

        const float E     = easeOutQuad(std::clamp(elapsedMs(ZOOM.startedAt) / LAUNCH_ZOOM_MS, 0.F, 1.F));
        const float GROWN = 1.F + (LAUNCH_ZOOM_SCALE - 1.F) * E;
        const float W     = sc<float>(ZOOM.from.width) * GROWN;
        const float H     = sc<float>(ZOOM.from.height) * GROWN;

        // pivot_point (0.5, 0.5): it grows about its own centre.
        float x = sc<float>(ZOOM.from.x) - (W - sc<float>(ZOOM.from.width)) / 2.F;
        float y = sc<float>(ZOOM.from.y) - (H - sc<float>(ZOOM.from.height)) / 2.F;

        // Z11 (user): GNOME's blow-up drifts UPWARD off a bottom dock. Its
        // clamp is baked into the tween's END STATE and EASED from frame one
        // (`translation_y: containedY - scaledY` inside the same ease) --
        // per-frame clamping only engages once the box already hits the edge,
        // which read as "expands in all directions".
        const float MONW = sc<float>(monitor->m_size.x) * monitor->m_scale;
        const float MONH = sc<float>(monitor->m_size.y) * monitor->m_scale;
        const float FW   = sc<float>(ZOOM.from.width) * LAUNCH_ZOOM_SCALE;
        const float FH   = sc<float>(ZOOM.from.height) * LAUNCH_ZOOM_SCALE;
        const float FX   = sc<float>(ZOOM.from.x) - (FW - sc<float>(ZOOM.from.width)) / 2.F;
        const float FY   = sc<float>(ZOOM.from.y) - (FH - sc<float>(ZOOM.from.height)) / 2.F;
        x += (std::clamp(FX, 0.F, std::max(0.F, MONW - FW)) - FX) * E;
        y += (std::clamp(FY, 0.F, std::max(0.F, MONH - FH)) - FY) * E;

        CTexPassElement::SRenderData data;
        data.tex = TEX;
        data.box = CBox{std::round(x), std::round(y), std::round(W), std::round(H)};
        data.a   = 1.F - E;
        g_pHyprRenderer->m_renderPass.add(makeUnique<CTexPassElement>(data));
    }

    // Above the pill by construction (MENU_GAP), so the previews below cannot
    // overdraw it and it does not have to wait for them.
    renderMenu(monitor, LAYOUT);

    const auto NOW = Time::steadyNow();

    // X25. The REAL window, through the same path the overview tiles use --
    // which is the point of rebuilding the dock in C++ at all. An icon or a
    // cached screenshot here would be the defect the spec names.
    const auto drawWindowAt = [&](const PHLWINDOW& window, const CBox& box) { renderLivePreview(monitor, window, box, NOW); };

    // Y5. The flight is a real window at real SIZE, not a thumbnail, so where it
    // is legal it draws the way the overview draws a tile -- live blur, frost
    // scaled to the render scale, real decorations.
    //
    // It takes that path EVERYWHERE, desktop included -- which is the point of
    // the user's instruction. What differs off the overview is only PASS
    // OWNERSHIP: inside the overview the plugin owns the render pass and the
    // path may flush it mid-draw, while at RENDER_POST_WINDOWS a flush renders
    // and CLEARS everything Hyprland queued for the rest of the frame. Measured:
    // flushing there wedged the frame loop and stranded a restoring window on
    // the stash permanently. Blur scaling and forced live blur do not depend on
    // the flush, so the frost is correct in both.
    const bool OWNSPASS     = scrollOverviewForMonitor(monitor) != nullptr;
    const auto drawFlightAt = [&](const PHLWINDOW& window, const CBox& box, float alpha) {
        // Z9r5: a window hidden for its flight is skipped by the surface
        // machinery (validMapped), so the proxy rendered as border + tint with
        // no content -- measured, frame 130 of the zen film. Unhide strictly
        // around this draw: the compositor's own window pass ran before the
        // dock's chrome pass this frame, so it never observes the flip.
        const bool REHIDE = window->isHidden();
        if (REHIDE)
            window->setHidden(false);
        renderLivePreview(monitor, window, box, NOW, alpha, true, OWNSPASS);
        if (REHIDE)
            window->setHidden(true);
    };

    // X47. Over the pill, under the flight -- a window on its way into an icon
    // must not disappear behind the panel it flies past. Suppressed while the
    // X28 menu is up (the two plates would stack) and while the dock's own drag
    // is live (a panel following a dragged icon is noise, not information).
    //
    // Y1. The pointer INSIDE the plate wants it too. Hovering no icon is no
    // longer the same as wanting no panel, which is the whole bug: the panel
    // floats above the pill, so reaching a preview always leaves every icon box.
    const bool OVERPANEL   = panelContains(MOUSE);
    const bool PANELWANTED = (HASHOVER || OVERPANEL) && !g_menu && !dragging() && !dragPending();

    CBox        panelAnchor;
    std::string panelClass;
    if (PANELWANTED) {
        // Over the plate but not over an icon: keep the app it is already
        // showing, so crossing from icon to preview is one continuous panel.
        const bool FROMICON = HASHOVER;
        panelAnchor         = FROMICON ? HOVEREDITEM->iconBox : g_panel->anchor;
        panelClass          = FROMICON ? HOVEREDITEM->wmClass : g_panel->wmClass;
    }

    renderHoverPreview(monitor, LAYOUT, panelAnchor, panelClass, NOW);

    // The menu says the app's name louder than the tooltip does, and the two
    // plates would otherwise sit on top of each other.
    //
    // X47 makes the PANEL a third plate in the same place, so it suppresses the
    // name the same way -- a name plate under a wall of previews of that very
    // app is the stack the menu branch already refuses to draw.
    // ponytail: the panel therefore shows no text at all. Windows puts each
    // window's TITLE over its thumbnail; add that (labelPill per cell, it is
    // already shared with the overview caption) when per-window identification
    // matters, e.g. once G15's window rows land.
    //
    // The empty-name call is what drives the fade-OUT: without it the plate would
    // simply stop being drawn, which is the pop X57 is removing.
    // Y2 retires that ponytail note: per-window identification matters now. A
    // preview under the pointer names ITS OWN window -- the full title, not the
    // app -- on the same plate, with the same fade, one gap above the panel.
    // Tested FIRST because while the panel is up the pointer is in it rather
    // than on an icon, and the title is the more specific answer of the two.
    const auto CELL = panelUp() ? panelCellAt(MOUSE) : std::optional<std::pair<CBox, PHLWINDOW>>{};

    if (g_menu)
        renderTooltip(monitor, LAYOUT, CBox{}, "");
    else if (CELL && !CELL->second->m_title.empty())
        renderTooltip(monitor, LAYOUT, CELL->first, CELL->second->m_title, sc<float>(g_panelDrawn.y));
    else if (!panelUp()) {
        if (HASHOVER)
            renderTooltip(monitor, LAYOUT, HOVEREDITEM->iconBox, itemName(*HOVEREDITEM));
        else if (HOVERAPPS)
            renderTooltip(monitor, LAYOUT, LAYOUT.showApps, "Show Applications");
        else
            renderTooltip(monitor, LAYOUT, CBox{}, "");
    } else
        renderTooltip(monitor, LAYOUT, CBox{}, "");

    // X46. A minimize now flies into the app's OWN ICON. It used to fly into the
    // preview slot the minimize itself created, which is the entry X46 deletes;
    // the icon is where the window goes and where a click gets it back, so it is
    // the honest target. Ends when the clock runs out, or immediately if the
    // icon went away (app closed mid-flight).
    // Y5. GNOME's minimize at GNOME's numbers -- 400ms on EASE_OUT_EXPO, with
    // the window FADING as it scales, because `_minimizeWindow` eases opacity
    // to 0 inside the same tween as scale and position.
    //
    // Y4 made "minimize the whole app" the default gesture, so this is a LIST:
    // a three-window app is three flights, and the old single-slot version
    // would have teleported two of them on an ordinary click.
    for (auto it = g_flights.begin(); it != g_flights.end();) {
        const auto  WINDOW = it->window.lock();
        const float T      = flightProgress(*it);
        const auto  ITEM   = WINDOW ? std::ranges::find_if(LAYOUT.items, [&](const SItem& item) { return item.wmClass == WINDOW->m_class; }) : LAYOUT.items.end();

        if (!WINDOW || T >= 1.F || ITEM == LAYOUT.items.end()) {
            zdbg("flightEnd win=%d T=%f item=%d restoring=%d held=%d\n", (int)(bool)WINDOW, T, ITEM != LAYOUT.items.end(), (int)it->isRestore(), it->landHeldFrames);
            if (WINDOW) {
                // X54. A restore that reaches its end -- or loses its icon -- is
                // where the window actually comes back, because it stayed
                // stashed for the whole flight.
                //
                // Z4. Restore-then-erase in ONE frame left a frame with neither
                // proxy nor real window on screen -- the restore lands the
                // window in the NEXT frame's window pass at the earliest, and
                // the user read the hole as "it's an image, not the window".
                // So: restore, hold the proxy at its landing box this frame,
                // erase on the next pass, when the real window overlaps it
                // exactly (same box, same content -- the seam is invisible).
                // Z17/Z18: ANY restoring flight that ends -- landing, lost
                // icon, mode confusion -- leaves the window SANE: unhidden,
                // full alpha, geometry at the target. A driven flight owns its
                // geometry (warp to the frozen target); a proxy flight's goals
                // were never touched (warp value to goal). The hidden case
                // still bridges two held frames so the unhide has a composited
                // frame to land on.
                if (it->isRestore() && WINDOW->isHidden() && it->landHeldFrames < LAND_HOLD_FRAMES) {
                    if (!it->isLanding()) { // the first landing frame does the unhide
                        WINDOW->setHidden(false);
                        warpRestoredWindowAnims(WINDOW);
                        WINDOW->alpha()[Desktop::View::WINDOW_ALPHA_FADE]->setValueAndWarp(1.F);
                        // Z20: setHidden fires no event; without this the
                        // overview's draw list never re-adds the window -- a
                        // clickable, invisible tile (grid and hit-test iterate
                        // live, the render walks the list).
                        if (const auto OVERVIEW = scrollOverviewForMonitor(monitor))
                            OVERVIEW->refreshWindows();
                    }
                    it->phase = EFlightPhase::Landing;
                    ++it->landHeldFrames;
                    drawFlightAt(WINDOW, it->from, 1.F);
                    ++it;
                    continue;
                }
                if (it->isRestore()) {
                    if (it->isDriven()) {
                        const float SCALE = std::max(monitor->m_scale, 0.01F);
                        const Vector2D POS{it->from.x / SCALE + monitor->m_position.x, it->from.y / SCALE + monitor->m_position.y};
                        const Vector2D SZ{std::max(4.0, it->from.width / SCALE), std::max(4.0, it->from.height / SCALE)};
                        WINDOW->m_realPosition->m_Value = POS;
                        WINDOW->m_realSize->m_Value     = SZ;
                        // Z18b: the LAYOUT TARGET too. Minimize captures
                        // TARGET->position(), not the anim vars -- landing
                        // without this write-back left the target at its
                        // pre-flight record, and the SECOND cycle restored to
                        // stale geometry (900x600 on screen, 500x495 captured).
                        if (WINDOW->m_isFloating) {
                            if (const auto TARGET = WINDOW->layoutTarget(); TARGET) {
                                TARGET->setPositionGlobal(CBox{POS.x, POS.y, SZ.x, SZ.y});
                                TARGET->warpPositionSize();
                            }
                        }
                    } else
                        warpRestoredWindowAnims(WINDOW);
                    WINDOW->alpha()[Desktop::View::WINDOW_ALPHA_FADE]->setValueAndWarp(1.F);
                } else {
                    // A MINIMIZE flight landed. The window kept focus for the
                    // whole flight so the flying proxy stayed bright (Zen no
                    // longer darkens mid-flight, and a spam of clicks no longer
                    // flickers it); hand the keyboard off now (deferred X33).
                    Minimize::handoffMinimizedFocus(WINDOW);
                }
            }

            it = g_flights.erase(it);
            continue;
        }

        const float E  = easeOutExpo(T);
        const float A0 = it->alphaFrom;
        CBox        box;
        float       alpha;

        if (it->isDriven() && !Minimize::isMinimized(WINDOW)) {
            // Z17: the DESKTOP restore is the real window, driven natively --
            // no proxy draw at all. The target is the layout's live goal, so a
            // retile mid-flight retargets the flight for free.
            const float SCALE = std::max(monitor->m_scale, 0.01F);
            const CBox  START = it->start.width >= 1 ? it->start : ITEM->iconBox;
            box               = lerpBox(START, it->from, E);
            alpha             = (A0 >= 0.F ? A0 : 0.F) * (1.F - E) + E;

            WINDOW->m_realPosition->m_Value = Vector2D{box.x / SCALE + monitor->m_position.x, box.y / SCALE + monitor->m_position.y};
            WINDOW->m_realSize->m_Value     = Vector2D{std::max(4.0, box.width / SCALE), std::max(4.0, box.height / SCALE)};
            WINDOW->alpha()[Desktop::View::WINDOW_ALPHA_FADE]->setValueAndWarp(alpha);

            it->lastDrawn = box;
            it->lastAlpha = alpha;
            zdbg("drive r=1 box=%f,%f %fx%f a=%f\n", box.x, box.y, box.width, box.height, alpha);
            ++it;
            continue;
        }

        if (it->isRestore()) {
            // Overview path: proxy machinery (Y5 divergence: GNOME does NOT
            // fade a window back in; the user asked for "fade out/in").
            const CBox START = it->start.width >= 1 ? it->start : ITEM->iconBox;
            box              = lerpBox(START, it->from, E);
            alpha            = (A0 >= 0.F ? A0 : 0.F) * (1.F - E) + E;
        } else {
            const CBox START = it->start.width >= 1 ? it->start : it->from;
            box              = lerpBox(START, ITEM->iconBox, E);
            alpha            = (A0 >= 0.F ? A0 : 1.F) * (1.F - E);
        }

        it->lastDrawn = box;
        it->lastAlpha = alpha;
        {
            const auto& GC = WINDOW->m_realBorderColor.m_colors;
            zdbg("draw r=%d box=%f,%f %fx%f a=%f bc=%02x%02x%02x\n", (int)it->isRestore(), box.x, box.y, box.width, box.height, alpha,
                 GC.empty() ? 0 : sc<int>(GC[0].r * 255.F), GC.empty() ? 0 : sc<int>(GC[0].g * 255.F), GC.empty() ? 0 : sc<int>(GC[0].b * 255.F));
        }
        // Z16 (user): "shadows and the thin window outline do not stay on the
        // window as it maximizes". The proxy is a bare surface; a real window
        // carries Hyprland's shadow and border. Same shadow pass the overview
        // cards use, and the window's own border gradient (focused by Z9, so
        // the active colours), both riding the flight's box and alpha.
        OvInternal::renderOverviewWorkspaceShadow(monitor, box, 1.F, false, alpha);
        drawFlightAt(WINDOW, box, alpha);
        {
            const int BORDERSIZE = std::max(0, ScrollOverview::Config::getValue<int>("general:border_size"));
            if (BORDERSIZE > 0 && alpha > 0.01F) {
                CBorderPassElement::SBorderData border;
                border.box        = box;
                border.grad1      = WINDOW->m_realBorderColor;
                border.a          = alpha;
                border.borderSize = BORDERSIZE;
                border.round      = sc<int>(sc<float>(ScrollOverview::Config::getValue<int>("decoration:rounding")) * monitor->m_scale);
                g_pHyprRenderer->m_renderPass.add(makeUnique<CBorderPassElement>(border));
            }
        }
        ++it;
    }

    for (const auto& PREVIEW : LAYOUT.previews)
        drawWindowAt(PREVIEW.window, PREVIEW.box);

    // X47. The panel needs the same loop: its entrance, its travel and its live
    // previews all need frames nothing else on an idle desktop would ask for.
    // Y6/Y8 join it: a bounce and a launch zoom both run on a dock nothing else
    // is touching, and neither is in damageIfChanged's signature.
    if (LAYOUT.previews.empty() && g_flights.empty() && !panelUp() && g_bounces.empty() && g_launchZooms.empty())
        return;

    // X25. A minimized window sits on a hidden workspace, so its commits damage
    // no monitor and nothing else on an idle desktop asks for a frame. The
    // damage that keeps the preview live cannot be asked for here -- it is
    // cleared with this frame's ring -- and render.pre only runs when a frame is
    // ALREADY happening, so from there the loop can never start itself. doLater
    // lands it after the frame, which both starts and sustains the loop.
    // ponytail: whole-monitor damage at the refresh rate while anything is
    // minimized. The pill's rectangle would do, but damageBox wants global
    // logical coords and the layout is monitor-local render px; convert it if
    // this ever shows up in a profile.
    g_pEventLoopManager->doLater([MONITOR = PHLMONITORREF{monitor}] {
        if (MONITOR)
            g_pHyprRenderer->damageMonitor(MONITOR.lock());
    });
}

}

// The runnable check for X27 is scripts/x27_gate.py: it measures the pill that
// actually landed on screen against the reference numbers. A pure-math assert
// was considered and dropped -- it would have had to link the whole plugin, and
// the proportions are exactly the thing a pixel measurement proves better.
//
// X25's is scripts/x25_gate.py, and it asks the one question a still frame
// cannot: two frames of the same minimized window, and the preview must have
// CHANGED between them.
