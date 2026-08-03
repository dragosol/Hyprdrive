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
// X53. 1:1 WITH THE HOST'S DASH-TO-DOCK, and every number below is MEASURED
// off a screen recording of the two docks side by side -- not derived from a
// rule of mine. The earlier passes at this invented a self-consistent rule
// ("every gap equal") and then a halved one, and neither matched the host.
//
// Ratios are what make the comparison scale-agnostic (the VM is a scaled window
// in that recording), so each value is given against the 54px icon both docks
// use:
//
//   icon                       54     both, dash-max-icon-size
//   halo (highlight-icon)/2     6     highlight 66 = 54 + 2*6      0.111 icon
//   gap between highlights      4     pitch 70 - highlight 66      0.074 icon
//   icon edge to icon edge     16     pitch 70 - icon 54           0.296 icon
//   highlight -> pill L/R      10                                  0.185 icon
//   highlight -> pill top      12                                  0.222 icon
//   highlight -> pill bottom   14                                  0.259 icon
//   pill height                92     = 12 + 66 + 14
//
// The vertical padding is ASYMMETRIC on purpose: the host's stylesheet says
// padding-top 10 / padding-bottom 14, the extra band being room for the running
// dot, and the recording measures 12/14. So the old
// `ITEM_PAD_TOP == ITEM_PAD_BOTTOM` assert is GONE -- it encoded a symmetry the
// reference does not have. `ITEM_PAD_TOP == CONTAINER_PAD_X + ITEM_MARGIN_X` is
// gone for the same reason: the host is 10px from the left edge and 12px from
// the top, so the icon is NOT equidistant from every pill edge and pretending
// otherwise is what kept this from matching.
constexpr float HOVER_PAD  = 6.F;   // the halo the highlight adds around an icon
constexpr float ICON_GAP   = 16.F;  // icon edge to icon edge, at rest
constexpr float HL_PAD_L   = 10.F;  // highlight to pill, left and right
constexpr float HL_PAD_TOP = 12.F;  // highlight to pill, top
constexpr float HL_PAD_BOT = 14.F;  // highlight to pill, bottom

// Derived, so the measurements above stay the only things anyone edits.
constexpr float HIGHLIGHT_GAP   = ICON_GAP - 2.F * HOVER_PAD;
constexpr float ITEM_MARGIN_X   = ICON_GAP / 2.F;
constexpr float CONTAINER_PAD_X = HL_PAD_L + HOVER_PAD - ITEM_MARGIN_X;
constexpr float ITEM_PAD_TOP    = HL_PAD_TOP + HOVER_PAD;
constexpr float ITEM_PAD_BOTTOM = HL_PAD_BOT + HOVER_PAD;
constexpr float EDGE_MARGIN     = 4.F;

// The measurements restated as arithmetic, so a build that stops matching the
// host cannot compile.
static_assert(HIGHLIGHT_GAP > 0.F, "X53: a hover highlight must not reach into the icon next to it");
static_assert(2.F * ITEM_MARGIN_X == ICON_GAP, "X53: icon edge to icon edge must be ICON_GAP");
static_assert(CONTAINER_PAD_X + ITEM_MARGIN_X - HOVER_PAD == HL_PAD_L, "X53: the first highlight must sit HL_PAD_L from the pill's left edge");
static_assert(ITEM_PAD_TOP - HOVER_PAD == HL_PAD_TOP, "X53: a highlight must sit HL_PAD_TOP from the pill's top");
static_assert(ITEM_PAD_BOTTOM - HOVER_PAD == HL_PAD_BOT, "X53: a highlight must sit HL_PAD_BOT from the pill's bottom");

// X25. A preview is as TALL as an icon -- it shares the icon row -- and as wide
// as the window's own aspect makes it. The clamp is what stops one ultrawide or
// one tall-and-thin window from owning the pill; it is not a look, it is a
// bound, which is why it is a constant and not a config key.
constexpr float PREVIEW_MIN_ASPECT = 0.60F;
constexpr float PREVIEW_MAX_ASPECT = 2.20F;

// (user, 2026-08-03) hover highlight and tooltip, read off the GNOME shell the
// user showed: a rounded cell slightly larger than the icon, and a dark plate
// above the dock carrying the app's name.
constexpr float TOOLTIP_FONT   = 13.F;
constexpr float TOOLTIP_PAD_X  = 10.F;
constexpr float TOOLTIP_PAD_Y  = 6.F;
constexpr float TOOLTIP_RADIUS = 8.F;
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
constexpr float DOT_MARGIN_B = 2.F;

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
struct SFlight {
    PHLWINDOWREF window;
    CBox         from; // monitor-local RENDER px
    Time::steady_tp startedAt;
};

// ponytail: one flight at a time. A shift-click minimizes a whole app, and only
// the last of those animates; the rest teleport as they did before. Per-window
// flights if that ever reads as wrong.
std::optional<SFlight> g_flight;

// A minimize is an exit, so it accelerates. This used to be a cubic mirror --
// the right SHAPE but not the house curve; houseEase evaluates the registered
// bezier itself, so the dock and the overview are exactly the same motion.
float exitEase(float t) {
    return houseEase(false, t);
}

float flightLinearProgress() {
    if (!g_flight)
        return 1.F;

    const int DURATION = Config::getValue<int>(KEY_MINIMIZE_MS);
    if (DURATION <= 0)
        return 1.F;

    return std::clamp(sc<float>(std::chrono::duration<float, std::milli>(Time::steadyNow() - g_flight->startedAt).count()) / sc<float>(DURATION), 0.F, 1.F);
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

// The user's own `org.gnome.shell favorite-apps`, in order, dumped 2026-08-02
// and recorded in RICE_PROGRESS.md. It seeds an EMPTY store only -- an id that
// no desktop entry claims is dropped at layout time, not here, so this list
// stays the reference's rather than being quietly filtered down to whatever the
// test VM happens to have installed.
constexpr std::array<const char*, 14> DEFAULT_FAVORITES = {
    "app.zen_browser.zen", "com.discordapp.Discord",  "org.gnome.Nautilus",    "net.thunderbird.Thunderbird", "steam",
    "claude-desktop",      "lmstudio",                "org.gnome.Calendar",    "org.gnome.Software",          "md.obsidian.Obsidian",
    "org.gnome.TextEditor", "io.github.tobagin.karere", "net.lutris.Lutris",   "org.gnome.Ptyxis",
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
};

std::unordered_map<MONITORID, SReveal> g_reveal;

// The barrier is the monitor's last row, and the cursor is clamped there -- but
// a clamp can leave it a pixel short, so the band is not exactly one row.
constexpr float EDGE_BAND = 2.F;

float elapsedMs(const Time::steady_tp& since) {
    return sc<float>(std::chrono::duration<float, std::milli>(Time::steadyNow() - since).count());
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

// The standing Apple-motion rule again: entrances decelerate, exits accelerate.
// The DURATION stays the reference's `animation-time` in BOTH directions -- the
// rule shapes the curve, the reference pins the number.
// Revealing is an entrance, hiding an exit. Same two house curves, so the dock
// slide matches every other transition in the rice.
float revealEase(float t, bool showing) {
    return houseEase(showing, t);
}

// 0 = fully out, 1 = fully tucked below the bottom edge.
float hiddenFraction(PHLMONITOR monitor) {
    if (!monitor)
        return 0.F;

    const auto& R  = g_reveal[monitor->m_id];
    const int   MS = std::max(1, Config::getValue<int>(KEY_AUTOHIDE_MS));
    const float E  = revealEase(std::clamp(elapsedMs(R.changedAt) / sc<float>(MS), 0.F, 1.F), R.shown);

    return R.shown ? 1.F - E : E;
}

bool autohideAnimating(PHLMONITOR monitor) {
    if (!monitor)
        return false;

    const auto& R = g_reveal[monitor->m_id];
    return R.pending || elapsedMs(R.changedAt) < sc<float>(std::max(1, Config::getValue<int>(KEY_AUTOHIDE_MS)));
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

    bool       want   = false;
    if (R.shown) {
        // Up already: it stays up while the pointer is on it, or while its
        // right-click menu is -- the menu floats ABOVE the pill, so reaching for
        // a row takes the pointer off the pill and would otherwise slide the
        // dock out from under the menu the user is aiming at.
        const auto BASE = baseLayout(monitor);
        if (menuOpen())
            want = true;
        else if (!BASE.pill.empty()) {
            CBox reach = BASE.pill;
            reach.height += EDGE_MARGIN * monitor->m_scale; // the margin under the pill still counts as on it
            want = reach.containsPoint((g_pInputManager->getMouseCoordsInternal() - monitor->m_position) * monitor->m_scale);
        }
    } else
        want = R.pressure >= Config::getValue<float>(KEY_PRESSURE); // `require-pressure-to-show`

    // X34 `hotkeys-show-dock`, ORed in beside URGENT for the same reason: it has
    // to HOLD the pill up as well as bring it out, or the pointer sitting
    // anywhere else would slide it away under the numbers the press just drew.
    want = want || URGENT || overlayHoldsDock();

    if (want == R.shown) {
        R.pending = false;
        return;
    }

    if (!R.pending) {
        R.pending      = true;
        R.pendingSince = Time::steadyNow();
    }

    if (elapsedMs(R.pendingSince) < sc<float>(std::max(0, Config::getValue<int>(want ? KEY_SHOW_DELAY : KEY_HIDE_DELAY))))
        return;

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

    const double DY = std::round((out.pill.height + EDGE_MARGIN * monitor->m_scale) * F);
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
// It sits in the bottom padding rather than owning it: ITEM_PAD_BOTTOM's own
// comment reserved this, and the dot's 5+2 clears the icon by 5px.
void renderRunningDot(PHLMONITOR monitor, const SLayout& layout, const SItem& item) {
    const float SCALE  = std::max(monitor->m_scale, 0.01F);
    const float SIZE   = std::max(1.F, sc<float>(Config::getValue<int>(KEY_DOT_SIZE)) * SCALE);
    const float CX     = sc<float>(item.iconBox.x) + sc<float>(item.iconBox.width) / 2.F;
    const float BOTTOM = sc<float>(layout.pill.y) + sc<float>(layout.pill.height) - DOT_MARGIN_B * SCALE;

    const uint32_t ARGB = Config::getValue<uint32_t>(KEY_DOT_COLOR);

    CRectPassElement::SRectData dot;
    dot.box   = CBox{std::round(CX - SIZE / 2.F), std::round(BOTTOM - SIZE), std::round(SIZE), std::round(SIZE)};
    dot.color = CHyprColor{sc<float>((ARGB >> 16) & 0xFF) / 255.F, sc<float>((ARGB >> 8) & 0xFF) / 255.F, sc<float>(ARGB & 0xFF) / 255.F, sc<float>((ARGB >> 24) & 0xFF) / 255.F};
    // `border-radius: 5px` on a 5px box: a circle. Half the size, so it stays one
    // when the dot is themed larger.
    // Truncated, not rounded: a radius even slightly OVER half the box collapses
    // the circle into a diamond, and the stock 5px dot rounds to 3 against a
    // half-width of 2.5. Seen on screen 2026-08-03.
    dot.round         = sc<int>(SIZE / 2.F);
    dot.roundingPower = 2.F;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(dot));
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

void renderTooltip(PHLMONITOR monitor, const SLayout& layout, const CBox& anchor, const std::string& NAME) {
    if (NAME.empty())
        return;

    const float SCALE = std::max(monitor->m_scale, 0.01F);
    const auto  TEX   = OverviewRender::text(NAME, CHyprColor{1.F, 1.F, 1.F, 1.F}, std::max(1, sc<int>(std::round(TOOLTIP_FONT * SCALE))), false, "", 0, 500);
    if (!TEX || !TEX->ok())
        return;

    const float PADX  = TOOLTIP_PAD_X * SCALE;
    const float PADY  = TOOLTIP_PAD_Y * SCALE;
    const float W     = sc<float>(TEX->m_size.x) + 2.F * PADX;
    const float H     = sc<float>(TEX->m_size.y) + 2.F * PADY;
    const float CX    = sc<float>(anchor.x) + sc<float>(anchor.width) / 2.F;

    CBox plate{std::round(CX - W / 2.F), std::round(sc<float>(layout.pill.y) - TOOLTIP_GAP * SCALE - H), std::round(W), std::round(H)};

    // Keep it on screen when the hovered icon is at either end of a wide pill.
    plate.x = std::clamp(plate.x, 0.0, std::max(0.0, monitor->m_size.x * SCALE - plate.width));

    CRectPassElement::SRectData bg;
    bg.box           = plate;
    bg.color         = CHyprColor{0.F, 0.F, 0.F, 0.80F};
    bg.round         = sc<int>(std::round(TOOLTIP_RADIUS * SCALE));
    bg.roundingPower = 2.F;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(bg));

    CTexPassElement::SRenderData text;
    text.tex = TEX;
    text.box = CBox{std::round(plate.x + PADX), std::round(plate.y + PADY), sc<float>(TEX->m_size.x), sc<float>(TEX->m_size.y)};
    text.a   = 1.F;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CTexPassElement>(text));
}

// X24. Stash first, then fly. Order matters: minimize() is what stops the
// compositor drawing the real window, so doing it up front is what keeps the
// flight from being a second copy of a window that is still on screen.
void minimizeWithFlight(PHLMONITOR monitor, PHLWINDOW window) {
    const int  DURATION = Config::getValue<int>(KEY_MINIMIZE_MS);
    const bool ANIMATE  = monitor && window && DURATION > 0 && !Minimize::isMinimized(window);

    // The overview tile, not the window's real box: while the dock is on screen
    // the overview is too, and the tile is what the user is watching. Must be
    // read before the stash, which moves the window off the tiled workspace.
    CBox from;
    if (ANIMATE) {
        const auto OVERVIEW = scrollOverviewForMonitor(monitor);
        if (OVERVIEW)
            from = OVERVIEW->tileBox(window);
    }

    Minimize::minimize(window);

    if (ANIMATE && from.width >= 1 && from.height >= 1)
        g_flight = SFlight{.window = window, .from = from, .startedAt = Time::steadyNow()};
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
void launchApp(PHLMONITOR monitor, const SItem& item) {
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

void activateItem(PHLMONITOR monitor, const SItem& item, bool shift) {
    // X35. A location has no windows to minimize: it is opened. Nautilus raises
    // the window it already has for a location rather than opening a second
    // one, so this is the reference's "focus it" too.
    if (!item.uri.empty()) {
        launchApp(monitor, item);
        return;
    }

    const auto windows = classWindows(item.wmClass);

    // X45. NO WINDOWS: launch.
    if (windows.empty()) {
        launchApp(monitor, item);
        return;
    }

    // `minimize-shift` survives X45 unchanged: shift takes the WHOLE app down
    // whatever the count, and brings it all back when it is already down.
    if (shift) {
        std::vector<PHLWINDOW> visible;
        for (const auto& WINDOW : windows) {
            if (!Minimize::isMinimized(WINDOW))
                visible.emplace_back(WINDOW);
        }

        if (visible.empty()) {
            for (const auto& WINDOW : windows)
                Minimize::restore(WINDOW);
            return;
        }

        for (const auto& WINDOW : visible)
            minimizeWithFlight(monitor, WINDOW);
        return;
    }

    // X45. TWO OR MORE WINDOWS: the click CYCLES. This replaces X24's
    // "minimize whatever is in front", which could only ever reach one of them.
    // activateWindow() restores a minimized window on the way, so the cycle
    // covers windows sitting in the icon as well as windows on screen -- there
    // is no state a cycle cannot reach.
    if (windows.size() > 1) {
        cycleThroughWindows(item.wmClass, false);
        return;
    }

    // X45. EXACTLY ONE WINDOW: the click is a toggle against that window --
    // minimize it into its own icon, and the next click brings it back.
    //
    // Decided by the window's OWN state, not by focus. Focus was the first cut
    // and it made the minimize branch dead: the pill is only ever up while the
    // overview is (§10 clause 6) and the overview owns the focus while it is
    // up, so focusState()->window() is never a dock app's window. Measured
    // 2026-08-03, two clicks and nothing minimized either time.
    const auto& WINDOW = windows.front();
    if (Minimize::isMinimized(WINDOW))
        Minimize::restore(WINDOW);
    else
        minimizeWithFlight(monitor, WINDOW);
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

    // X13/X29: frost is on for every surface, so the menu gets the pill's own.
    COverviewBlurPassElement::SData blur;
    blur.box            = plate;
    blur.rounding       = sc<int>(std::round(MENU_RADIUS * SCALE));
    blur.roundingPower  = 2.F;
    blur.alpha          = 1.F;
    blur.xray           = false;
    blur.blurSize       = Config::getValue<int>(KEY_BLUR_SIZE);
    blur.blurPasses     = Config::getValue<int>(KEY_BLUR_PASSES);
    blur.blurBrightness = Config::getValue<float>(KEY_BLUR_BRIGHT);
    blur.blurNoise      = Config::getValue<float>(KEY_BLUR_NOISE);
    blur.blurContrast   = Config::getValue<float>(KEY_BLUR_CONTR);
    blur.blurVibrancy   = Config::getValue<float>(KEY_BLUR_VIBR);
    g_pHyprRenderer->m_renderPass.add(makeUnique<COverviewBlurPassElement>(blur));

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
            CRectPassElement::SRectData fill;
            fill.box           = row.box;
            fill.color         = CHyprColor{1.F, 1.F, 1.F, 0.12F};
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

bool click(PHLMONITOR monitor, const Vector2D& point, bool shift, bool middle) {
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

    activateItem(monitor, *ITEM, shift);
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

void render(PHLMONITOR monitor) {
    const auto LAYOUT = layout(monitor);
    if (LAYOUT.pill.empty())
        return;

    // X13/X29: frost is always on, and it is the REFERENCE's frost --
    // blur-my-shell's `[dash-to-dock]` sigma 30 / brightness 0.60 / no grain,
    // not the desktop's window blur. `static-blur` is false there, so this stays
    // live. Queued directly rather than through OverviewRender::queueBlur: the
    // overrides ride on the element because the blur runs inside draw(), long
    // after this function has returned.
    //
    // `unblur-in-overview` is false in the reference, and the overview now draws
    // this same call, so the pill keeps its frost there instead of losing it.
    COverviewBlurPassElement::SData blur;
    blur.box            = LAYOUT.pill;
    blur.rounding       = LAYOUT.rounding;
    blur.roundingPower  = 2.F;
    blur.alpha          = 1.F;
    blur.xray           = false;
    blur.blurSize       = Config::getValue<int>(KEY_BLUR_SIZE);
    blur.blurPasses     = Config::getValue<int>(KEY_BLUR_PASSES);
    blur.blurBrightness = Config::getValue<float>(KEY_BLUR_BRIGHT);
    blur.blurNoise      = Config::getValue<float>(KEY_BLUR_NOISE);
    blur.blurContrast   = Config::getValue<float>(KEY_BLUR_CONTR);
    blur.blurVibrancy   = Config::getValue<float>(KEY_BLUR_VIBR);
    g_pHyprRenderer->m_renderPass.add(makeUnique<COverviewBlurPassElement>(blur));

    CRectPassElement::SRectData bg;
    bg.box           = LAYOUT.pill;
    bg.color         = background();
    bg.round         = LAYOUT.rounding;
    bg.roundingPower = 2.F;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(bg));

    // (user, 2026-08-03): GNOME lights the hovered app cell with a translucent
    // lighter fill and a slightly stronger outline, and labels it. Mouse coords
    // are global logical; the layout is monitor-local RENDER px.
    const auto MOUSE       = (g_pInputManager->getMouseCoordsInternal() - monitor->m_position) * monitor->m_scale;
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
        CRectPassElement::SRectData fill;
        fill.box           = hoverBox(HASHOVER ? HOVEREDITEM->iconBox : LAYOUT.showApps, monitor->m_scale);
        fill.color         = CHyprColor{1.F, 1.F, 1.F, 0.10F};
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
        if (const auto TEX = OverviewRender::appIcon(Config::getValue<std::string>(KEY_SHOW_APPS_ICON)); TEX) {
            CTexPassElement::SRenderData data;
            data.tex = TEX;
            data.box = LAYOUT.showApps;
            data.a   = 1.F;
            g_pHyprRenderer->m_renderPass.add(makeUnique<CTexPassElement>(data));
        }
    }

    // The menu says the app's name louder than the tooltip does, and the two
    // plates would otherwise sit on top of each other.
    if (!g_menu) {
        if (HASHOVER)
            renderTooltip(monitor, LAYOUT, HOVEREDITEM->iconBox, itemName(*HOVEREDITEM));
        else if (HOVERAPPS)
            renderTooltip(monitor, LAYOUT, LAYOUT.showApps, "Show Applications");
    }

    // Above the pill by construction (MENU_GAP), so the previews below cannot
    // overdraw it and it does not have to wait for them.
    renderMenu(monitor, LAYOUT);

    const auto NOW = Time::steadyNow();

    // X25. The REAL window, through the same path the overview tiles use --
    // which is the point of rebuilding the dock in C++ at all. An icon or a
    // cached screenshot here would be the defect the spec names.
    const auto drawWindowAt = [&](const PHLWINDOW& window, const CBox& box) {
        forcePreviewVisible(window);

        const auto  SIZE        = window->m_realSize->value();
        const float RENDERSCALE = SIZE.y >= 1.0 ? sc<float>(box.height / (SIZE.y * monitor->m_scale)) : 1.F;

        OverviewWindow::renderOverviewWindow({
            .monitor     = monitor,
            .window      = window,
            .windowBox   = box,
            .renderScale = RENDERSCALE,
            .now         = NOW,
        });

        presentPreview(window, monitor, NOW);
    };

    // X46. A minimize now flies into the app's OWN ICON. It used to fly into the
    // preview slot the minimize itself created, which is the entry X46 deletes;
    // the icon is where the window goes and where a click gets it back, so it is
    // the honest target. Ends when the clock runs out, or immediately if the
    // icon went away (app closed mid-flight).
    if (g_flight) {
        const auto WINDOW = g_flight->window.lock();
        const float T     = flightLinearProgress();
        const auto  ITEM  = WINDOW ? std::ranges::find_if(LAYOUT.items, [&](const SItem& item) { return item.wmClass == WINDOW->m_class; }) : LAYOUT.items.end();

        if (!WINDOW || T >= 1.F || ITEM == LAYOUT.items.end())
            g_flight.reset();
        else
            drawWindowAt(WINDOW, lerpBox(g_flight->from, ITEM->iconBox, exitEase(T)));
    }

    for (const auto& PREVIEW : LAYOUT.previews)
        drawWindowAt(PREVIEW.window, PREVIEW.box);

    if (LAYOUT.previews.empty() && !g_flight)
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
