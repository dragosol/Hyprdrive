#include "Dock.hpp"

#include "AppSearch.hpp"
#include "Config.hpp"
#include "IOverview.hpp"
#include "Minimize.hpp"
#include "OverviewPassElement.hpp"
#include "OverviewRender.hpp"
#include "Window.hpp"

#include <algorithm>
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
constexpr float ITEM_PAD_TOP    = 12.F;
constexpr float ITEM_PAD_BOTTOM = 12.F;
constexpr float ITEM_MARGIN_X   = 2.F;
constexpr float CONTAINER_PAD_X = 10.F;
constexpr float EDGE_MARGIN     = 4.F;

// The check for the above, and it costs nothing at runtime. Horizontally the
// icon is already CONTAINER_PAD_X + ITEM_MARGIN_X clear of both ends by
// construction, so top/bottom is the only pair that can drift.
static_assert(ITEM_PAD_TOP == ITEM_PAD_BOTTOM, "dock icons must sit equidistant from the pill's top and bottom");
static_assert(ITEM_PAD_TOP == CONTAINER_PAD_X + ITEM_MARGIN_X, "hoverInset() assumes the icon is the same distance from every pill edge");

// X25. A preview is as TALL as an icon -- it shares the icon row -- and as wide
// as the window's own aspect makes it. The clamp is what stops one ultrawide or
// one tall-and-thin window from owning the pill; it is not a look, it is a
// bound, which is why it is a constant and not a config key.
constexpr float PREVIEW_MIN_ASPECT = 0.60F;
constexpr float PREVIEW_MAX_ASPECT = 2.20F;

// (user, 2026-08-03) hover highlight and tooltip, read off the GNOME shell the
// user showed: a rounded cell slightly larger than the icon, and a dark plate
// above the dock carrying the app's name.
constexpr float HOVER_PAD      = 6.F;
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

// The standing Apple-motion rule (RICE_PROGRESS, user 2026-08-03): entrances
// decelerate, exits ACCELERATE and run 20-30% faster. A minimize is an exit, so
// this is the mirror of the house ease-out cubic rather than a reuse of it.
float exitEase(float t) {
    const float T = std::clamp(t, 0.F, 1.F);
    return T * T * T;
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

// X27 shows what is RUNNING. Favourites, pinning and ordering are X32; until
// then the order is the compositor's own window order, which is stable across
// frames -- an MRU order here would make the dock reshuffle on every focus.
std::vector<std::string> runningClasses() {
    std::vector<std::string>        out;
    std::unordered_set<std::string> seen;

    for (const auto& windowRef : Desktop::windowState()->windows()) {
        const auto& WINDOW = windowRef;
        if (!WINDOW || !WINDOW->m_isMapped || WINDOW->m_class.empty())
            continue;

        if (seen.insert(WINDOW->m_class).second)
            out.emplace_back(WINDOW->m_class);
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

}

SLayout layout(PHLMONITOR monitor) {
    SLayout out;

    if (!monitor || !Config::getValue<bool>(KEY_ENABLED) || monitor->m_size.x < 1 || monitor->m_size.y < 1)
        return out;

    const auto CLASSES   = runningClasses();
    const auto MINIMIZED = previewWindows();
    if (CLASSES.empty() && MINIMIZED.empty())
        return out;

    std::vector<float> aspects;
    aspects.reserve(MINIMIZED.size());
    float units = sc<float>(CLASSES.size());
    for (const auto& WINDOW : MINIMIZED) {
        aspects.emplace_back(previewAspect(WINDOW));
        units += aspects.back();
    }

    const float SCALE    = std::max(monitor->m_scale, 0.01F);
    const float ICONMAX  = sc<float>(std::clamp(Config::getValue<int>(KEY_ICON_SIZE), 8, 512));
    const float FRACTION = std::clamp(Config::getValue<float>(KEY_FRACTION), 0.05F, 1.F);
    const auto  M        = metrics(CLASSES.size() + MINIMIZED.size(), units, ICONMAX, FRACTION * sc<float>(monitor->m_size.x));

    // `extend-height` false and `always-center-icons` false: a floating pill
    // sized to its contents, centred on the monitor, clear of the bottom edge.
    const float XL = (sc<float>(monitor->m_size.x) - M.width) / 2.F;
    const float YL = sc<float>(monitor->m_size.y) - EDGE_MARGIN - M.height;

    out.pill = CBox{XL * SCALE, YL * SCALE, M.width * SCALE, M.height * SCALE};
    out.pill.round();
    out.rounding = std::max(0, sc<int>(std::round(sc<float>(Config::getValue<int>(KEY_RADIUS)) * SCALE)));

    float cursor = XL + CONTAINER_PAD_X + ITEM_MARGIN_X;
    out.items.reserve(CLASSES.size());
    for (const auto& CLASS : CLASSES) {
        SItem item;
        item.wmClass = CLASS;
        item.icon    = AppSearch::iconForClass(CLASS);
        item.iconBox = CBox{cursor * SCALE, (YL + ITEM_PAD_TOP) * SCALE, M.icon * SCALE, M.icon * SCALE};
        item.iconBox.round();
        out.items.emplace_back(std::move(item));

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
void renderTooltip(PHLMONITOR monitor, const SLayout& layout, const SItem& item) {
    const auto NAME = [&] {
        const auto FROMENTRY = AppSearch::appNameForClass(item.wmClass);
        return FROMENTRY.empty() ? item.wmClass : FROMENTRY;
    }();

    if (NAME.empty())
        return;

    const float SCALE = std::max(monitor->m_scale, 0.01F);
    const auto  TEX   = g_pHyprRenderer->renderText(NAME, CHyprColor{1.F, 1.F, 1.F, 1.F}, std::max(1, sc<int>(std::round(TOOLTIP_FONT * SCALE))), false, "", 0, 500);
    if (!TEX || !TEX->ok())
        return;

    const float PADX  = TOOLTIP_PAD_X * SCALE;
    const float PADY  = TOOLTIP_PAD_Y * SCALE;
    const float W     = sc<float>(TEX->m_size.x) + 2.F * PADX;
    const float H     = sc<float>(TEX->m_size.y) + 2.F * PADY;
    const float CX    = sc<float>(item.iconBox.x) + sc<float>(item.iconBox.width) / 2.F;

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
// There is deliberately no launch branch. The dock lists RUNNING classes until
// X32 brings favourites in, so every icon here already owns a window; a launch
// path written now would have nothing to launch from.
std::vector<PHLWINDOW> classWindows(const std::string& wmClass) {
    std::vector<PHLWINDOW> out;
    for (const auto& WINDOW : Desktop::windowState()->windows()) {
        if (WINDOW && WINDOW->m_isMapped && WINDOW->m_class == wmClass)
            out.emplace_back(WINDOW);
    }

    return out;
}

void activateClass(PHLMONITOR monitor, const std::string& wmClass, bool shift) {
    const auto windows = classWindows(wmClass);

    if (windows.empty())
        return;

    // The toggle is driven by what is ON SCREEN, not by what has focus.
    //
    // Focus was the first cut and it made the minimize branch DEAD: the pill is
    // only ever up while the overview is (§10 clause 6), the overview owns the
    // focus while it is up, so focusState()->window() is never a dock app's
    // window and every click fell through to "bring it forward". Measured
    // 2026-08-03 -- two clicks on an icon, activewindow unchanged both times,
    // nothing minimized. Nothing else uses this path, so nothing caught it.
    std::vector<PHLWINDOW> visible;
    for (const auto& WINDOW : windows) {
        if (!Minimize::isMinimized(WINDOW))
            visible.emplace_back(WINDOW);
    }

    // Whole app already down, so the click brings it back. Restore raises and
    // focuses on its own (X43).
    if (visible.empty()) {
        for (const auto& WINDOW : windows)
            Minimize::restore(WINDOW);
        return;
    }

    // `minimize-shift`: shift takes the whole app down, not just the window in
    // front. Same action as a plain click otherwise, since `shift-click-action`
    // is also minimize.
    if (shift) {
        for (const auto& WINDOW : visible)
            minimizeWithFlight(monitor, WINDOW);
        return;
    }

    // ponytail: `activate-single-window` is exact for one window, which is the
    // case that matters. Picking among several is X28's "All Windows" menu; the
    // front of the compositor's stack is the stand-in until it exists.
    minimizeWithFlight(monitor, visible.back());
}

// ---------------------------------------------------------------- X28 menu --

enum class ERow : uint8_t { Separator, Action, Window, Details, Favorite, Quit };

struct SRow {
    ERow         kind = ERow::Separator;
    std::string  label;
    std::string  exec;   // ERow::Action
    PHLWINDOWREF window; // ERow::Window
    CBox         box;    // monitor-local RENDER px, filled by renderMenu
};

struct SMenu {
    MONITORID         monitor = MONITOR_INVALID;
    std::string       wmClass;
    CBox              anchor; // the icon cell the menu hangs off
    CBox              box;    // the whole plate, filled by renderMenu
    std::vector<SRow> rows;
};

std::optional<SMenu> g_menu;

// Favourites are a LIST OF DESKTOP IDS, the same unit GNOME's `favorite-apps`
// key uses, so X32 can adopt this store rather than replace it. A plain file,
// because a plugin cannot write a Hyprland config key back out and this is user
// data rather than a tunable.
std::filesystem::path favoritesPath() {
    if (const char* STATE = std::getenv("XDG_STATE_HOME"); STATE && *STATE)
        return std::filesystem::path{STATE} / "scrolloverview" / "favorites";

    if (const char* HOME = std::getenv("HOME"); HOME && *HOME)
        return std::filesystem::path{HOME} / ".local" / "state" / "scrolloverview" / "favorites";

    return {};
}

std::vector<std::string>& favorites() {
    static std::vector<std::string> cache;
    static bool                     loaded = false;

    if (!loaded) {
        loaded = true;

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

void toggleFavorite(const std::string& id) {
    if (id.empty())
        return;

    auto& FAV = favorites();
    if (const auto IT = std::ranges::find(FAV, id); IT != FAV.end())
        FAV.erase(IT);
    else
        FAV.emplace_back(id);

    const auto PATH = favoritesPath();
    if (PATH.empty())
        return;

    std::error_code ec;
    std::filesystem::create_directories(PATH.parent_path(), ec);

    std::ofstream out(PATH, std::ios::trunc);
    for (const auto& F : FAV)
        out << F << "\n";
}

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
std::vector<SRow> buildRows(const std::string& wmClass) {
    std::vector<SRow> rows;

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

void activateRow(PHLMONITOR monitor, const std::string& wmClass, const SRow& row) {
    switch (row.kind) {
        case ERow::Separator: return;

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

        auto tex = g_pHyprRenderer->renderText(ROW.label, CHyprColor{1.F, 1.F, 1.F, 0.95F}, FONTPX, false, "", 0, 500);
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

bool pillContains(PHLMONITOR monitor, const Vector2D& point) {
    if (!monitor)
        return false;

    const auto PILL = layout(monitor).pill;
    return PILL.width >= 1 && PILL.height >= 1 && PILL.containsPoint(point);
}

bool click(PHLMONITOR monitor, const Vector2D& point, bool shift) {
    if (!monitor)
        return false;

    const auto LAYOUT = layout(monitor);
    if (LAYOUT.pill.width < 1 || LAYOUT.pill.height < 1)
        return false;

    // A preview is one specific window, so it restores that window rather than
    // going through the class -- two minimized windows of one app are two
    // previews, and the class path could not tell them apart.
    for (const auto& PREVIEW : LAYOUT.previews) {
        if (PREVIEW.box.containsPoint(point)) {
            Minimize::restore(PREVIEW.window);
            return true;
        }
    }

    // Hit-test the same cell the hover highlight lights up, so what looks
    // clickable is what is clickable.
    const auto ITEM = std::ranges::find_if(LAYOUT.items, [&](const SItem& item) { return hoverBox(item.iconBox, monitor->m_scale).containsPoint(point); });
    if (ITEM == LAYOUT.items.end())
        return false;

    activateClass(monitor, ITEM->wmClass, shift);
    return true;
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

    g_menu = SMenu{.monitor = monitor->m_id, .wmClass = ITEM->wmClass, .anchor = ITEM->iconBox, .box = {}, .rows = buildRows(ITEM->wmClass)};
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
    const auto CLASS = g_menu->wmClass;
    const auto PICK  = *ROW;
    closeMenu();

    activateRow(monitor, CLASS, PICK);
    return true;
}

bool damageIfChanged(PHLMONITOR monitor) {
    if (!monitor)
        return false;

    const auto  LAYOUT = layout(monitor);
    std::string signature;
    if (!LAYOUT.pill.empty()) {
        signature = std::to_string(sc<int>(LAYOUT.pill.x)) + "," + std::to_string(sc<int>(LAYOUT.pill.width));
        for (const auto& ITEM : LAYOUT.items)
            signature += "|" + ITEM.wmClass;

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

        // X28. The menu is part of what the dock looks like, and its hovered row
        // moves with a bare pointer move exactly as the icon highlight does.
        if (g_menu && g_menu->monitor == monitor->m_id) {
            signature += "@" + g_menu->wmClass;
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

    if (HASHOVER) {
        // (user, 2026-08-03) A flat fill, no outline. The radius is CONCENTRIC
        // with the pill rather than a constant: the cell is inset from the pill
        // by the same amount on every side, so its curve only reads as parallel
        // to the dock's if the radius drops by that inset too.
        CRectPassElement::SRectData fill;
        fill.box           = hoverBox(HOVEREDITEM->iconBox, monitor->m_scale);
        fill.color         = CHyprColor{1.F, 1.F, 1.F, 0.10F};
        fill.round         = std::max(0, LAYOUT.rounding - sc<int>(std::round(hoverInset() * monitor->m_scale)));
        fill.roundingPower = 2.F;
        g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(fill));
    }

    for (const auto& ITEM : LAYOUT.items) {
        const auto TEX = OverviewRender::appIcon(ITEM.icon);
        if (!TEX)
            continue;

        CTexPassElement::SRenderData data;
        data.tex = TEX;
        data.box = ITEM.iconBox;
        data.a   = 1.F;
        g_pHyprRenderer->m_renderPass.add(makeUnique<CTexPassElement>(data));
    }

    // The menu says the app's name louder than the tooltip does, and the two
    // plates would otherwise sit on top of each other.
    if (HASHOVER && !g_menu)
        renderTooltip(monitor, LAYOUT, *HOVEREDITEM);

    // Above the pill by construction (MENU_GAP), so the previews below cannot
    // overdraw it and it does not have to wait for them.
    renderMenu(monitor, LAYOUT);

    if (LAYOUT.previews.empty())
        return;

    // X25. The REAL window, through the same path the overview tiles use --
    // which is the point of rebuilding the dock in C++ at all. An icon or a
    // cached screenshot here would be the defect the spec names.
    // X24. A flight is not a separate animation, it is this same loop drawing
    // one of the previews at an interpolated box on its way to its slot. It ends
    // when the clock runs out, or immediately if the slot went away (restored
    // or closed mid-flight).
    std::optional<CBox> flightBox;
    if (g_flight) {
        const float T    = flightLinearProgress();
        const auto  SLOT = std::ranges::find_if(LAYOUT.previews, [](const SPreview& p) { return p.window == g_flight->window; });
        if (T >= 1.F || SLOT == LAYOUT.previews.end())
            g_flight.reset();
        else
            flightBox = lerpBox(g_flight->from, SLOT->box, exitEase(T));
    }

    const auto NOW = Time::steadyNow();
    for (const auto& PREVIEW : LAYOUT.previews) {
        forcePreviewVisible(PREVIEW.window);

        const CBox  BOX         = (flightBox && PREVIEW.window == g_flight->window) ? *flightBox : PREVIEW.box;
        const auto  SIZE        = PREVIEW.window->m_realSize->value();
        const float RENDERSCALE = SIZE.y >= 1.0 ? sc<float>(BOX.height / (SIZE.y * monitor->m_scale)) : 1.F;

        OverviewWindow::renderOverviewWindow({
            .monitor     = monitor,
            .window      = PREVIEW.window,
            .windowBox   = BOX,
            .renderScale = RENDERSCALE,
            .now         = NOW,
        });

        presentPreview(PREVIEW.window, monitor, NOW);
    }

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
