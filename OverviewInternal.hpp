#pragma once

// Internal helpers shared by the scrollOverview translation units. Not installed,
// not an API -- this is the ~1900 lines of file-static helpers that used to sit on
// top of scrollOverview.cpp and pinned every method to that one file.
//
// ponytail: header-only, and it re-exports itself with a trailing using-directive so
// the moved code needed no edits. The namespace is not decoration -- these compile to
// exported symbols now, and `hyprlerp` / `axisValue` would otherwise collide with
// Hyprland's own. It is deliberately NOT nested under ScrollOverview:: -- that made
// unqualified Config:: resolve to ScrollOverview::Config. Split into real .cpp files
// when compile time starts to hurt.

#include "scrollOverview.hpp"

#include <cstdio>

#include "AppSearch.hpp"
#include "TileChrome.hpp"

namespace TileChrome = ScrollOverview::TileChrome;

#include <drm_fourcc.h>
#include <hyprgraphics/image/Image.hpp>
#include <hyprland/src/render/gl/GLTexture.hpp>
#include <unordered_set>
#include <algorithm>
#include <any>
#include <array>
#include <chrono>
#include <dlfcn.h>
#include <functional>
#include <limits>
#include <optional>
#include <unordered_map>
#include <linux/input-event-codes.h>
#include <state/WorkspaceState.hpp>
#define private public
#define protected public
#include <hyprland/src/render/gl/GLTexture.hpp>
#include <drm_fourcc.h>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/config/ConfigManager.hpp>
#include <hyprland/src/config/lua/ConfigManager.hpp>
#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/config/shared/animation/AnimationTree.hpp>
#include <hyprland/src/config/shared/complex/ComplexDataTypes.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/animation/AnimationManager.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/managers/KeybindManager.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/algorithm/Algorithm.hpp>
#include <hyprland/src/layout/space/Space.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/layout/algorithm/tiled/scrolling/ScrollingAlgorithm.hpp>
#include <hyprland/src/desktop/state/GlobalWindowController.hpp>
#include <hyprland/src/pointer/cursor/CursorShapeOverrideController.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/view/Group.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/Popup.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/state/ViewState.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/protocols/LayerShell.hpp>
#include <hyprland/src/devices/IKeyboard.hpp>
#include <hyprland/src/helpers/math/Math.hpp>
#include <hyprland/src/helpers/time/Time.hpp>
#include <hyprland/src/plugins/PluginSystem.hpp>
#include <hyprland/src/render/pass/BorderPassElement.hpp>
#include <hyprland/src/render/pass/Pass.hpp>
#include <hyprland/src/render/pass/ClearPassElement.hpp>
#include <hyprland/src/render/pass/PreBlurElement.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/render/pass/RendererHintsPassElement.hpp>
#include <hyprland/src/render/pass/SurfacePassElement.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
#include <hyprland/src/render/types.hpp>
#include <hyprland/src/render/decorations/CHyprGroupBarDecoration.hpp>
#include <hyprland/src/render/decorations/DecorationPositioner.hpp>
#include <hyprutils/utils/ScopeGuard.hpp>
#include <hyprutils/string/Numeric.hpp>
#undef protected
#undef private
#include "Config.hpp"
#include "Dock.hpp"
#include "DropIndicator.hpp"
#include "OverviewPassElement.hpp"
#include "Minimize.hpp"
#include "OverviewRender.hpp"
#include "Window.hpp"
#include "SearchProviders.hpp"

// Anything that eases by hand -- tile hover, tile press, the grid reflow -- goes
// through here, so the whole plugin is driven by the same two curve objects the
// open and close animations use. Global scope on purpose: TileChrome.cpp links
// to this exact symbol (_Z9houseEasebf) via its own extern declaration, so it
// must NOT move into OvInternal. Defined in scrollOverview.cpp.
float houseEase(bool decel, float t);

// Card chrome helpers (shadow + rounding) live in their own header so the dock
// can reach them without this everything-header. Included before the
// namespace opens because it opens OvInternal itself.
#include "OverviewChrome.hpp"

namespace OvInternal {

inline PHLWINDOW getOverviewFullscreenVisibilityWindow(const PHLWORKSPACE& workspace, const PHLWINDOW& fallback = {});
inline constexpr const char* OVERVIEW_SUBMAP = "scrolloverview";
inline CScrollOverview*      g_pointerGrabOverview = nullptr;

inline void removeOverview(CScrollOverview* overview) {
    const auto PMONITOR = overview ? overview->pMonitor.lock() : PHLMONITOR{};
    unregisterScrollOverview(overview);
    if (scrollOverviews().empty())
        disableScrollOverviewHooks();

    if (PMONITOR) {
        PMONITOR->recheckSolitary();
        g_pHyprRenderer->damageMonitor(PMONITOR);
    }
}

inline xkb_keysym_t getOverviewKeysym(const IKeyboard::SKeyEvent& event) {
    const auto PKEYBOARD = g_pSeatManager->m_keyboard.lock();

    if (!PKEYBOARD)
        return XKB_KEY_NoSymbol;

    xkb_state* const STATE = PKEYBOARD->m_resolveBindsBySym && PKEYBOARD->m_xkbSymState ? PKEYBOARD->m_xkbSymState : PKEYBOARD->m_xkbState;

    if (!STATE)
        return XKB_KEY_NoSymbol;

    return xkb_state_key_get_one_sym(STATE, event.keycode + 8);
}

inline bool hasOverviewSubmap() {
    return g_pKeybindManager && std::ranges::any_of(g_pKeybindManager->m_keybinds, [](const auto& keybind) { return keybind && keybind->submap.name == OVERVIEW_SUBMAP; });
}

// Whether the submap binds any KEY, as opposed to only mouse buttons.
// Tested on the key STRING, not SKeybind::mouse: a plain `bind` whose key is
// "mouse:272" leaves that flag false (it marks bindm-style drag binds), so the
// flag alone counted this rice's two click binds as keyboard binds and kept the
// keyboard hook uninstalled -- measured 2026-08-01, arrows and Return dead.
inline bool hasOverviewSubmapKeyBinds() {
    return g_pKeybindManager && std::ranges::any_of(g_pKeybindManager->m_keybinds, [](const auto& keybind) {
        return keybind && keybind->submap.name == OVERVIEW_SUBMAP && !keybind->mouse && !keybind->key.starts_with("mouse");
    });
}

inline bool isOverviewSubmapActive() {
    return g_pKeybindManager && g_pKeybindManager->getCurrentSubmap().name == OVERVIEW_SUBMAP;
}

inline bool isTopLayerFocused(PHLMONITOR monitor) {
    const auto FOCUSEDSURFACE = g_pSeatManager->m_state.keyboardFocus.lock();

    if (!FOCUSEDSURFACE)
        return false;

    const auto HLSURFACE = Desktop::View::CWLSurface::fromResource(FOCUSEDSURFACE);
    if (!HLSURFACE)
        return false;

    const auto VIEW = HLSURFACE->view();
    if (!VIEW)
        return false;

    auto layerOwner = Desktop::View::CLayerSurface::fromView(VIEW);

    if (!layerOwner) {
        const auto POPUP = Desktop::View::CPopup::fromView(VIEW);
        if (POPUP) {
            const auto T1OWNER = POPUP->getT1Owner();
            if (T1OWNER)
                layerOwner = Desktop::View::CLayerSurface::fromView(T1OWNER->view());
        }
    }

    return layerOwner && layerOwner->m_monitor == monitor && layerOwner->m_layer >= ZWLR_LAYER_SHELL_V1_LAYER_TOP;
}

inline constexpr const char* OVERVIEW_INSERT_FADE_BEZIER = "scrolloverviewWorkspaceInsertFade";
inline constexpr const char* OVERVIEW_REMOVE_FADE_BEZIER = "scrolloverviewWorkspaceRemoveFade";

// The overview's own entrance and exit curves. Both end flat rather than
// overshooting -- an overview that bounces reads as a toy, and a bounce on the
// exit fights the reversal, because a reversed close would have to unwind an
// overshoot it had already started.
//
// These are the rice's two shared curves -- `appleDecel` / `appleAccel` in
// hyprland/general.lua and in the quickshell Appearance.qml. The plugin cannot
// reference a config curve by name, so the control points are duplicated here:
// change all three together or the rice stops speaking one motion language.
inline constexpr const char* OVERVIEW_OPEN_BEZIER  = HOUSE_DECEL_BEZIER;
inline constexpr const char* OVERVIEW_CLOSE_BEZIER = HOUSE_ACCEL_BEZIER;

// houseEase lives at GLOBAL scope, declared above the namespace and defined in
// scrollOverview.cpp. It is the one helper other translation units link to by
// symbol: TileChrome.cpp extern-declares `float houseEase(bool, float)` and the
// original split swept the definition into OvInternal:: with everything else,
// which renamed the exported symbol and left _Z9houseEasebf undefined. A shared
// object links fine with undefined symbols and dlopen resolves lazily, so the
// compositor died at the first mid-close tile ease, not at load: ld.so's error
// path exits 127, and a garbage PLT jump gives "segfault at X ip X".
// scripts/symcheck.sh now diffs against the host's exports instead of grepping
// for a namespace, precisely so the next global-scope symbol cannot hide.

inline bool isPointerOnTopLayer(PHLMONITOR monitor) {
    if (!monitor)
        return false;

    const auto MOUSECOORDS = g_pInputManager->getMouseCoordsInternal();
    Vector2D   surfaceCoords;
    PHLLS      layerSurface;

    if (Desktop::viewState()->hitTest().layerSurfaceAt(MOUSECOORDS, &monitor->m_layerSurfaceLayers[ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY], &surfaceCoords, &layerSurface))
        return true;

    return !!Desktop::viewState()->hitTest().layerSurfaceAt(MOUSECOORDS, &monitor->m_layerSurfaceLayers[ZWLR_LAYER_SHELL_V1_LAYER_TOP], &surfaceCoords, &layerSurface);
}

inline PHLWINDOW getOverviewWindowToShow(const PHLWINDOW& window) {
    if (!window)
        return nullptr;

    if (window->m_group)
        return window->m_group->current();

    return window;
}

// OVERVIEW_CPP_SPEC §13.4 G5. TWO LAYOUTS, TWO CAPS, and the caps are PER
// PROVIDER. Apps are a grid and cap at 6; every other provider is a list and
// caps at 5 ROWS EACH, not 5 shared. A shared cap is what made X49's section
// cards invisible: a query matching 5 apps starved every provider, so there was
// only ever one card to categorise.
inline constexpr size_t OVERVIEW_APP_RESULT_LIMIT      = 6;
inline constexpr size_t OVERVIEW_PROVIDER_ROW_LIMIT    = 5;

// X19: the panel shows ONE ordered list. Local app entries first -- they are an
// in-memory scan and always instant -- then whatever the SearchProvider2
// providers have answered with so far. Providers arrive asynchronously, so this
// is deliberately a snapshot: the list grows across frames as replies land, and
// a provider that never answers simply never appears.
struct SSearchRow {
    std::string              name;
    // G6/X66: kept apart from the name rather than glued on with spaces. GNOME
    // draws these as two columns -- a bright name, then a dimmer description --
    // and one concatenated string cannot be coloured two ways.
    std::string              description;
    std::string              icon;
    const AppSearch::SEntry* app = nullptr;
    SearchProviders::SResult provider;
};

// G6. How many results each provider offered, INCLUDING the ones the cap and
// the trim never showed. Filled by overviewSearchRows(); read by the section
// header to say "%d more".
inline std::unordered_map<std::string, size_t> g_providerTotals;

inline std::vector<SSearchRow> overviewSearchRows() {
    std::vector<SSearchRow> rows;
    if (g_overviewSearch.empty())
        return rows;

    Prof::Timer PROF{Prof::rowsNs, Prof::rowsCalls};

    for (const auto* E : AppSearch::search(g_overviewSearch, OVERVIEW_APP_RESULT_LIMIT))
        rows.push_back({E->name, "", E->icon, E, {}});

    // G5: each provider gets its OWN five rows. Providers arrive in whatever
    // order they answer, so the count is kept per id rather than by assuming
    // results() is grouped.
    std::unordered_map<std::string, size_t> perProvider;
    for (const auto& R : SearchProviders::results()) {
        if (perProvider[R.providerDesktopId]++ >= OVERVIEW_PROVIDER_ROW_LIMIT)
            continue;
        // X66. There used to be a skip here for "the provider for an app we
        // already list is the same row twice". It threw away EVERY result from
        // a provider whose own app happened to match the query -- so searching
        // "e" put Characters and Files in the apps grid and silently deleted
        // both of their categories, which is the "only icons, no other results"
        // the user reported. GNOME does not do this: its apps grid and its
        // provider sections are independent, and its Calculator section lists
        // "Open in Calculator" whether or not Calculator is also an app match.
        rows.push_back({R.name, R.description, R.icon, nullptr, R});
    }

    // G6 needs to know how many a provider ACTUALLY had, so the header can say
    // how many are not being shown. perProvider counted every result, including
    // the ones the cap skipped, so it is that total already.
    g_providerTotals = std::move(perProvider);
    return rows;
}

// X49. One card per provider. The grouping happens once, here, because the band
// maths and the render pass have to agree on how many cards there are and how
// many rows each one holds -- deriving that twice is how a panel ends up taller
// than the band it was allocated.
struct SSearchSection {
    std::string         title;
    std::string         icon;
    std::vector<size_t> rows;  // indices into the overviewSearchRows() vector
    size_t              total = 0; // G6: how many the provider had, cap included
    // G5: which of the two layouts this section draws in. Apps are the GRID of
    // icons; every other provider is a LIST of rows under a G6 header.
    bool                grid = false;
};

inline std::vector<SSearchSection> overviewSearchSections(const std::vector<SSearchRow>& rows) {
    std::vector<SSearchSection> out;
    std::vector<std::string>    keys;

    for (size_t i = 0; i < rows.size(); ++i) {
        // Apps share one key: they are the section the reference puts above the
        // provider cards, and they have no provider of their own to name.
        const std::string KEY = rows[i].app ? "" : rows[i].provider.providerDesktopId;

        if (const auto IT = std::ranges::find(keys, KEY); IT != keys.end()) {
            out[sc<size_t>(IT - keys.begin())].rows.push_back(i);
            continue;
        }

        keys.push_back(KEY);
        const auto TOTALIT = g_providerTotals.find(KEY);

        // G6: the header carries the PROVIDER APPLICATION's icon and name,
        // which is a different app from the one the row itself points at.
        // entryForId is the only way to reach it, and a provider whose .desktop
        // is missing keeps its bare id rather than drawing a headerless card.
        SSearchSection section{.title = "Applications",
                               .icon  = "applications-other",
                               .rows  = {i},
                               .total = TOTALIT == g_providerTotals.end() ? 0 : TOTALIT->second,
                               .grid  = KEY.empty()};
        if (!KEY.empty()) {
            section.title = KEY;
            section.icon  = KEY;
            if (const auto* ENTRY = AppSearch::entryForId(KEY); ENTRY) {
                section.title = ENTRY->name;
                section.icon  = ENTRY->icon;
            }
        }
        out.push_back(std::move(section));
    }

    return out;
}


// OVERVIEW_CPP_SPEC §13.4 G12. The result rows as they were last DRAWN. Same
// contract as the dock's own menu rows: a row's box is only known inside the
// render pass, so the hit-test answers against the last frame -- which is the
// frame the user was looking at when they pressed.
struct SSearchRowHit {
    CBox        box;
    std::string desktopId; // "" for a provider row: those are not draggable
    std::string icon;
    // X62. Which result this box belongs to. The hit-test existed only to
    // reject drops before; answering the mouse means the hit has to say WHICH
    // result was hit, in the same index space the keyboard selection uses.
    int         index = -1;
};
inline std::vector<SSearchRowHit> g_searchRowHits;

// G12. A result drag: press, HOLD, then move. The hold is the gate and the
// distance is not, so a click can never turn into a drag no matter how far the
// hand wobbles inside it.
struct SResultDrag {
    std::string     desktopId;
    std::string     icon;
    Vector2D        start;
    Time::steady_tp startedAt;
    bool            live = false;
    int             index = -1; // X62: the row the PRESS landed on
};
inline std::optional<SResultDrag> g_resultDrag;

inline constexpr float G12_HOLD_MS = 200.F;

inline const SSearchRowHit* searchRowAt(const Vector2D& point) {
    const auto IT = std::ranges::find_if(g_searchRowHits, [&](const SSearchRowHit& row) { return row.box.containsPoint(point); });
    return IT == g_searchRowHits.end() ? nullptr : &*IT;
}

// X62. Activating a result is ONE act however it was chosen -- Return on the
// keyboard selection, or a plain click on the row. Sharing the helper is the
// point: G12 built the drag and left the click undefined, and a second copy of
// "launch or activate" is how the mouse and the keyboard end up disagreeing
// about what the selected row does.
inline bool activateSearchResult(int index) {
    const auto RESULTS = overviewSearchRows();
    if (index < 0 || index >= sc<int>(RESULTS.size()))
        return false;

    const auto& ROW = RESULTS[index];
    if (ROW.app)
        AppSearch::launch(*ROW.app, ScrollOverview::Config::getTerminal());
    else
        SearchProviders::activate(ROW.provider, g_overviewSearch);

    return true;
}

// OVERVIEW_CPP_SPEC §5 F2, and §13.7 X18's open-window half.
//
// Open windows ARE the window search result: they are already the grid's tiles,
// already promoted from other desktops by B2 and already animated in by F3-b,
// so a second result ROW for a window the user can see would be the same window
// twice in one view. What X18 buys is PARITY OF MATCHING with
// windows-search-provider@G-dH, and the host's own settings were read rather
// than its defaults: `search-method` is 0 = Strict, so the fuzzy app scorer is
// the WRONG algorithm here. Strict is every space-separated term appearing
// somewhere, in any order, case- and accent-insensitively.
//
// Haystack is the extension's own, `${wsIndex + 1}: ${title} ${appName}`, plus
// the window class -- dropping the class would regress the F2 behaviour that
// shipped long before X18.
// Counts RENDERED frames, which is the only clock this code actually advances
// on: an idle overview renders nothing, so a wall-clock "last touched" measures
// how long the user sat still rather than whether the tile was drawn.
// ponytail: one counter for all monitors, so a second output would advance it
// twice per frame and every tile would read as skipped; make it per-monitor if
// this ever runs on more than one.
inline uint64_t g_overviewFrame = 0;

inline bool overviewSearchMatches(const PHLWINDOW& window) {
    if (g_overviewSearch.empty())
        return true;

    Prof::Timer PROF{Prof::matchNs, Prof::matchCalls};

    // X52 secondary. ~40 call sites consult this gate, so one frame asks the
    // same question about the same window dozens of times -- measured 617-1041
    // calls per frame over a 16-window fixture on the broad query `x`, each one
    // rebuilding the haystack from scratch. The answer cannot change within a
    // frame, so cache it for the frame.
    //
    // The key carries the QUERY as well as the frame counter, not a generation
    // number someone has to remember to bump: a keystroke lands between frames,
    // and the query is 1-3 characters, so comparing it is cheaper than the
    // allocation this skips. Liveness (validMapped) stays OUTSIDE the memo, in
    // shouldShowOverviewWindow, so an unmapped window is never served from here.
    static uint64_t                                                memoFrame = ~0ULL;
    static std::string                                             memoQuery;
    static std::unordered_map<Desktop::View::CWindow*, bool>       memo;

    if (memoFrame != g_overviewFrame || memoQuery != g_overviewSearch) {
        memo.clear();
        memoFrame = g_overviewFrame;
        memoQuery = g_overviewSearch;
    } else if (const auto IT = memo.find(window.get()); IT != memo.end())
        return IT->second;

    // Hyprland numbers regular workspaces from 1, which is what the extension
    // renders as `wsIndex + 1`, so typing "2:" finds desktop 2 on both.
    std::string haystack = window->m_workspace ? std::format("{}: ", window->m_workspace->m_id) : "";
    haystack += window->m_title + " " + window->m_class;

    if (const auto APPNAME = AppSearch::appNameForClass(window->m_class); !APPNAME.empty())
        haystack += " " + APPNAME;

    const bool MATCHED = AppSearch::strictMatch(g_overviewSearch, haystack);
    memo[window.get()] = MATCHED;
    return MATCHED;
}

// The search filter hangs off this gate rather than off the grid builder: every
// overview path (render, hit-test, drag, grid) already consults it, so they
// cannot disagree about which windows exist. Dropping a window from the gate
// removes it from the grid too, and the survivors re-lay-out through the U4
// reflow animation at no extra cost.
inline bool shouldShowOverviewWindow(const PHLWINDOW& window) {
    // Z9r5: a window hidden for a dock flight is the proxy's alone -- drawing
    // its tile too would be the double image the spec forbids.
    if (window && window->isHidden())
        return false;

    const auto WINDOW = getOverviewWindowToShow(window);

    if (!validMapped(WINDOW))
        return false;

    if (WINDOW->m_pinned && WINDOW->m_isFloating)
        return false;

    // Y9 REVISED (user, 2026-08-06): a minimized window belongs in the overview
    // ONLY while a query is active. With an empty query it stays put away --
    // which is what minimizing it meant -- and this is X58(a)'s original wording
    // restored: "filtering needs to work even on minimized windows".
    //
    // The gate goes HERE and nowhere else on purpose. This function is the one
    // thing every overview path consults (see the note above it), so putting the
    // rule in it keeps render, hit-test, drag and grid from ever disagreeing
    // about whether a stashed window exists. The workspace-home plumbing in
    // overviewGridWindows and addOverviewWindow stays: it is what puts the
    // window on the RIGHT desktop once a query does bring it back.
    if (g_overviewSearch.empty() && ScrollOverview::Minimize::isMinimized(WINDOW))
        return false;

    if (!overviewSearchMatches(WINDOW))
        return false;

    return true;
}

inline bool shouldShowPinnedFloatingOverviewWindow(const PHLWINDOW& window) {
    const auto WINDOW = getOverviewWindowToShow(window);

    if (!validMapped(WINDOW))
        return false;

    if (!WINDOW->m_pinned || !WINDOW->m_isFloating)
        return false;

    return true;
}

inline bool surfaceTreeHasFrameCallbacks(SP<CWLSurfaceResource> surface) {
    if (!surface)
        return false;

    bool hasCallbacks = false;
    surface->breadthfirst(
        [&hasCallbacks](SP<CWLSurfaceResource> child, const Vector2D&, void*) {
            if (!child || child->m_current.callbacks.empty())
                return;

            hasCallbacks = true;
        },
        nullptr);

    return hasCallbacks;
}

inline void surfaceTreePresent(SP<CWLSurfaceResource> surface, PHLMONITOR monitor, const Time::steady_tp& now) {
    if (!surface)
        return;

    std::pair<PHLMONITOR, Time::steady_tp> data = {monitor, now};
    surface->breadthfirst([](SP<CWLSurfaceResource> child, const Vector2D&, void* data) {
        if (!child)
            return;

        const auto [MONITOR, NOW] = *sc<std::pair<PHLMONITOR, Time::steady_tp>*>(data);
        child->presentFeedback(NOW, MONITOR, false);
    }, &data);
}

inline bool windowHasOverviewAnimation(const PHLWINDOW& window) {
    if (!window)
        return false;

    return window->positionAnimation()->isBeingAnimated() || window->sizeAnimation()->isBeingAnimated() || window->m_alpha.isBeingAnimated() ||
        window->m_borderFadeAnimationProgress->isBeingAnimated() || window->m_borderAngleAnimationProgress->isBeingAnimated() || window->m_dimPercent->isBeingAnimated() ||
        window->m_shadowFadeAnimationProgress->isBeingAnimated();
}

inline bool layerHasOverviewAnimation(const PHLLS& layer) {
    if (!Desktop::View::validMapped(layer))
        return false;

    return layer->positionAnimation()->isBeingAnimated() || layer->sizeAnimation()->isBeingAnimated() || layer->m_alpha.isBeingAnimated();
}

// Mission-control grid, OVERVIEW_CPP_SPEC §5 B1. The focused workspace lays its
// windows out as a grid instead of at their real desktop positions. Implemented
// by swapping the source geometry inside getOverviewWindowBox, so rendering,
// hit-testing and drag all derive from the same box and cannot disagree.
inline std::vector<PHLWINDOW> overviewGridWindows(const PHLWORKSPACE& workspace) {
    std::vector<PHLWINDOW> windows;
    if (!workspace)
        return windows;

    for (const auto& window : Desktop::windowState()->windows()) {
        if (getOverviewWindowToShow(window) != window || !shouldShowOverviewWindow(window))
            continue;

        // Y9 (user): "when an app window is minimized it should still be
        // visible there, so I can see it and filter to it". A minimized window
        // is parked on the `special:minimized` stash, so its own m_workspace can
        // never equal a real one and the plain test below dropped it from every
        // grid. It belongs to the desktop it was minimized FROM, which is
        // exactly what Minimize records -- and the only source for it, since the
        // stash has overwritten the window's own answer.
        //
        // This also subsumes X58(a), which asked only that the SEARCH reach
        // minimized windows: they are in the grid now whether a query is typed
        // or not, and the query filters them like anything else.
        if (const auto HOME = ScrollOverview::Minimize::originalWorkspace(window); HOME != WORKSPACE_INVALID) {
            if (HOME != workspace->m_id)
                continue;
        } else if (window->m_workspace != workspace)
            continue;

        windows.emplace_back(window);
    }

    return windows;
}

// OVERVIEW_CPP_SPEC §5 B2. With a query typed, matches from every workspace join
// the ACTIVE workspace's grid. A promoted window keeps living in its own
// workspace's window list and is still drawn in that workspace's pass; what
// changes is that its box comes from the active grid and is placed at the active
// card's offset. Done here rather than by shuffling windows between the
// per-workspace loops so the B1 invariant holds: render, hit-test and drag all
// still read the same getOverviewWindowBox and cannot disagree.
inline bool overviewGridPromotable(const PHLWINDOW& window, PHLMONITOR monitor) {
    if (g_overviewSearch.empty() || !ScrollOverview::Config::getMissionControl() || !window || !monitor)
        return false;

    if (window->m_monitor != monitor)
        return false;

    const auto WORKSPACE = window->m_workspace;
    return WORKSPACE && WORKSPACE != monitor->m_activeWorkspace && shouldShowOverviewWindow(window);
}

// OVERVIEW_CPP_SPEC 13.2 F3-b, the symmetric half: "released back OUT to its own
// desktop as the query stops matching". The instant a promoted window stops
// matching it leaves the grid, so gridReflowBox is never called for it and it
// cuts -- the exact mirror of the pull-in defect. Keep it promoted for one
// reflow after the match dies so it still has somewhere to travel FROM.
//
// The clock is anchored to the FIRST FRAME THE MATCH IS SEEN TO BE GONE, not to
// the last frame it was seen present. That distinction is the whole ballgame:
// this runs only when something renders, and a static overview renders nothing.
// Timestamping "last seen matching" therefore measured idle time -- after a
// couple of idle seconds the release was already expired on the frame it was
// born and the tile cut. Measured: it made the fix land or not land at random,
// 1 of 2 runs at 300ms and 1 of 2 at 2000ms.
struct SGridRelease {
    PHLWINDOWREF    window;
    Time::steady_tp start;
    bool            started = false; // armed while matching, started when the match dies
};

inline std::unordered_map<Desktop::View::CWindow*, SGridRelease> g_gridReleases;

// The outbound ease starts on the first releasing frame, one frame after the
// last matching one, so the clock has to outlast the reflow or the tile is cut
// just short of home.
inline constexpr float GRID_RELEASE_GRACE_MS = 50.F;

inline bool overviewGridReleasing(const PHLWINDOW& window, PHLMONITOR monitor) {
    const int DURATION = ScrollOverview::Config::getMissionControlReflowMs();
    if (DURATION <= 0 || !window)
        return false;

    const auto NOW = Time::steadyNow();

    if (overviewGridPromotable(window, monitor)) {
        if (g_gridReleases.size() > 64)
            std::erase_if(g_gridReleases, [](const auto& entry) { return !entry.second.window.lock(); });

        g_gridReleases[window.get()] = SGridRelease{window, {}, false}; // armed, not running
        return false;
    }

    const auto IT = g_gridReleases.find(window.get());
    if (IT == g_gridReleases.end())
        return false;

    // A recycled address must not inherit a dead window's release, and a window
    // that unmapped mid-flight must stop being drawn -- the render gate below
    // trusts this function to have checked.
    if (IT->second.window.lock() != window || !validMapped(window)) {
        g_gridReleases.erase(IT);
        return false;
    }

    if (!IT->second.started) {
        IT->second.started = true;
        IT->second.start   = NOW; // the match died on THIS frame, whenever it is
    }

    if (ScrollOverview::Config::animElapsedMs(IT->second.start) > sc<float>(DURATION) + GRID_RELEASE_GRACE_MS) {
        g_gridReleases.erase(IT);
        return false;
    }

    return true;
}

inline bool overviewGridPromoted(const PHLWINDOW& window, PHLMONITOR monitor) {
    return overviewGridPromotable(window, monitor) || overviewGridReleasing(window, monitor);
}

// Membership of the MAIN grid. Identical to overviewGridWindows for an empty
// query. The strip deliberately keeps the workspace-scoped list: its minis and
// its "no matches" count both need the per-cell answer.
inline std::vector<PHLWINDOW> overviewMainGridWindows(const PHLWORKSPACE& workspace, PHLMONITOR monitor) {
    auto windows = overviewGridWindows(workspace);
    if (g_overviewSearch.empty() || !monitor)
        return windows;

    for (const auto& window : Desktop::windowState()->windows()) {
        // Promotable, not promoted: a RELEASING tile must leave the grid
        // immediately so the survivors close up WHILE it travels (F3-b-iii,
        // outbound). It keeps being drawn -- it just no longer owns a slot.
        if (getOverviewWindowToShow(window) == window && overviewGridPromotable(window, monitor))
            windows.emplace_back(window);
    }

    return windows;
}

inline Vector2D overviewGridWindowSize(const PHLWINDOW& window) {
    return window->geometricBox(Desktop::View::IGeometric::GEOMETRIC_CURRENT).size();
}

// Workspace thumbnail strip, OVERVIEW_CPP_SPEC §5 D'4 + E. A row of mini
// workspace previews along the top of the focused workspace card. It exists
// because at scale 0.82 the neighbour cards are ~180px slivers: there was
// nothing on screen to aim a drag at, and nowhere for D'4's post-drop preview
// to appear. Minis are real windows rendered small; spec §6 exempts them from
// frost, so this does not reopen section C.
inline float overviewStripLogicalHeight(PHLMONITOR monitor) {
    if (!ScrollOverview::Config::getStrip() || !monitor)
        return 0.F;

    const float H = sc<float>(ScrollOverview::Config::getStripHeight());
    return H > 1.F && H < sc<float>(monitor->m_size.y) / 2.F ? H : 0.F;
}

// X10: the search row above the strip. ponytail: constant 64 logical px
// (48px pill + 8px margins); make it a config knob if anyone ever asks.
inline constexpr float OVERVIEW_SEARCH_ROWHL = 64.F, OVERVIEW_SEARCH_DOCKPADL = 8.F;

// User, 2026-08-06: "place search results higher so that there isn't an awkward
// space between search bar and search results". The row is the full 64px while
// the pill sits in it, and shrinks as the pill docks away under the bar, so the
// results, the strip and the tiles all climb into the space the pill left.
//
// renderSearch writes this each frame from the pill's ACTUAL landed foot rather
// than from the dock progress, because the floor is the pill itself: collapsing
// the row outright puts the panel's head ABOVE the docked pill's foot and the
// two overlap. That was the r1 attempt this replaces.
inline float g_overviewSearchRowL = OVERVIEW_SEARCH_ROWHL;

inline float overviewSearchLogicalHeight(PHLMONITOR monitor) {
    return monitor ? g_overviewSearchRowL : 0.F;
}

// X50: how far down the monitor the top chrome reaches, in logical global px.
// The WORK AREA is no help: measured 2026-08-06, the rice's bar sets no
// exclusive zone -- `hyprctl monitors` reports reserved [0,0,0,0] while
// `quickshell:bar` occupies the top 63px -- so a dock target read from
// workArea() puts the pill UNDER the bar, which this pass draws after the whole
// overview. That is X10's occlusion finding reached from the other side, and it
// is what the first X50 build did.
// Only WIDE surfaces pinned to the monitor's top edge count: the same rice puts
// 250px screenCorners up there, and docking below one of those is a 23px move.
inline float overviewTopChromeBottomL(PHLMONITOR monitor) {
    if (!monitor)
        return 0.F;

    float bottom = sc<float>(monitor->m_position.y);
    for (const auto LEVEL : {ZWLR_LAYER_SHELL_V1_LAYER_TOP, ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY}) {
        for (auto const& lsRef : monitor->m_layerSurfaceLayers[LEVEL]) {
            const auto LS = lsRef.lock();
            if (!Desktop::View::validMapped(LS))
                continue;

            const auto& GEOM = LS->m_geometry;
            if (sc<float>(GEOM.w) < sc<float>(monitor->m_size.x) * 0.5F || sc<float>(GEOM.h) > sc<float>(monitor->m_size.y) / 3.F)
                continue;
            if (sc<float>(GEOM.y) > sc<float>(monitor->m_position.y) + 1.F)
                continue;

            bottom = std::max(bottom, sc<float>(GEOM.y + GEOM.h));
        }
    }

    return bottom;
}

// X21: the results panel is part of the LAYOUT STACK, not an overlay. Its band
// sits between the search row and the strip, so a growing list pushes the strip
// down and shrinks the grid instead of covering them. This is the EASED value
// (X23) mirrored out of CScrollOverview::resultsBand -- the free layout helpers
// below and the hit-test paths all read it, and none of them can reach a member.
inline float           g_overviewResultsBandH  = 0.F;
inline constexpr float OVERVIEW_RESULT_ROWHL = 34.F, OVERVIEW_RESULT_ROWGAPL = 6.F, OVERVIEW_RESULT_PANELPADL = 8.F, OVERVIEW_RESULT_PANELGAPL = 10.F;
// X49. The results are WIDE and CATEGORISED: one rounded card per provider, the
// provider's icon and name on the card's leading edge, its rows across the rest
// of the width. HEADERWL is that leading column; HEADERHL is the floor a card
// gets, so a one-row section still has room for a 32px provider icon.
inline constexpr float OVERVIEW_RESULT_SECTIONGAPL = 8.F, OVERVIEW_RESULT_HEADERWL = 168.F, OVERVIEW_RESULT_HEADERHL = 44.F;
// G5's OTHER layout. Apps are a grid of icon cells, not rows: a 48px icon with
// its name under it. CELLWL is the widest a cell gets -- the grid caps at 6 AND
// at whatever fits, so a narrow monitor wraps instead of overflowing.
inline constexpr float OVERVIEW_RESULT_CELLWL = 132.F, OVERVIEW_RESULT_CELLHL = 78.F, OVERVIEW_RESULT_CELLICONL = 48.F;

inline float overviewResultsLogicalHeight(PHLMONITOR monitor) {
    return monitor ? std::max(0.F, g_overviewResultsBandH) : 0.F;
}

// The width the result cards span: the monitor inset by the mission-control
// gap, which is the same span the grid tiles get (X49). The band maths and the
// render pass both need it, and a grid's height depends on it.
inline float overviewResultsSpanW(PHLMONITOR monitor) {
    if (!monitor)
        return 1.F;

    // X65 (user, 2026-08-05): "results blur should not take up 80% of the
    // screen width, maybe something like 50%". A result is an icon, a name and
    // a description -- it never needed the tile grid's full span, and at 86%
    // the frosted card was the largest thing on screen. Clamped so a narrow
    // monitor still leaves room for the G6 header column plus a usable row.
    const float GAPL = sc<float>(ScrollOverview::Config::getMissionControlGap());
    return std::clamp(sc<float>(monitor->m_size.x) * 0.5F, 1.F, std::max(1.F, sc<float>(monitor->m_size.x) - (GAPL * 2.F)));
}

// G5: the grid "caps at 6 and at whatever fits the width". The 6 is applied
// when the rows are gathered; this is the width half.
inline size_t overviewResultsGridCols(size_t cells, float spanWL) {
    const float INNER = std::max(1.F, spanWL - (OVERVIEW_RESULT_PANELPADL * 2.F));
    const auto  FITS  = sc<size_t>(std::max(1.F, std::floor(INNER / OVERVIEW_RESULT_CELLWL)));
    return std::max(sc<size_t>(1), std::min(cells, FITS));
}

// The logical height one card needs. A LIST card is its rows, its padding, and
// a floor so the G6 provider icon on the leading edge always fits a one-row
// section. A GRID card is however many cell rows the width forced it into.
inline float overviewResultsSectionHeight(const SSearchSection& section, float spanWL) {
    if (section.grid) {
        const float ROWS = std::ceil(sc<float>(section.rows.size()) / sc<float>(overviewResultsGridCols(section.rows.size(), spanWL)));
        return (OVERVIEW_RESULT_PANELPADL * 2.F) + (ROWS * OVERVIEW_RESULT_CELLHL) + ((ROWS - 1.F) * OVERVIEW_RESULT_ROWGAPL);
    }

    const float N    = sc<float>(section.rows.size());
    const float BODY = (N * OVERVIEW_RESULT_ROWHL) + ((N - 1.F) * OVERVIEW_RESULT_ROWGAPL);
    return (OVERVIEW_RESULT_PANELPADL * 2.F) + std::max(BODY, OVERVIEW_RESULT_HEADERHL);
}

// The height the band is easing TOWARD -- X49 sums the SECTION CARDS rather
// than a flat row count -- still capped by a BUDGET so that however many rows
// the query matches, the desktop strip and the window tiles stay on screen
// (DoD clause 23, whose PLACEMENT half X60 rewrote and whose "the overview
// stays visible" half is unchanged).
// X64. USER-REPORTED: "it should show just like gnome with results in
// categories" -- against a build that showed the apps icons and nothing else.
//
// renderSearch() drops any card that will not fit the band, and the apps grid is
// drawn FIRST, so an overflowing stack loses the PROVIDER categories entirely.
// G5 turned that from a latent ceiling into a daily one by raising the caps from
// 5 SHARED to 6 apps + 5 rows PER PROVIDER.
//
// So the stack is made to FIT before anything measures it: rows are given up
// from the tallest section first, and no section is ever taken below one row.
// Every category survives; the rows given up are what G6's "%d more" reports.
// Dropping a whole category to fit a box is never the answer -- the categories
// ARE the feature.
inline void overviewTrimSectionsToFit(std::vector<SSearchSection>& sections, PHLMONITOR monitor) {
    if (sections.empty() || !monitor)
        return;

    const float SPANWL = overviewResultsSpanW(monitor);
    // The same ceiling the band target uses, less the gaps it adds back, so the
    // two cannot disagree about what "fits" means.
    const float BUDGET = std::max(0.F, (sc<float>(monitor->m_size.y) / 2.F) - overviewSearchLogicalHeight(monitor) - (OVERVIEW_RESULT_PANELGAPL * 2.F));

    const auto stackHeight = [&] {
        float h = sc<float>(sections.size() - 1) * OVERVIEW_RESULT_SECTIONGAPL;
        for (const auto& SECTION : sections)
            h += overviewResultsSectionHeight(SECTION, SPANWL);
        return h;
    };

    while (stackHeight() > BUDGET) {
        const auto TALLEST = std::ranges::max_element(sections, {}, [&](const SSearchSection& SECTION) { return overviewResultsSectionHeight(SECTION, SPANWL); });
        if (TALLEST == sections.end() || TALLEST->rows.size() <= 1)
            break; // every category keeps a row, even if the stack still overflows

        TALLEST->rows.pop_back();
    }
}

inline float overviewResultsBandTarget(PHLMONITOR monitor, const std::vector<SSearchSection>& sections) {
    if (sections.empty() || !monitor)
        return 0.F;

    const float SPANWL = overviewResultsSpanW(monitor);

    float panelH = sc<float>(sections.size() - 1) * OVERVIEW_RESULT_SECTIONGAPL;
    for (const auto& SECTION : sections)
        panelH += overviewResultsSectionHeight(SECTION, SPANWL);

    // X60: the band now sits UNDER the search row and above the strip, so the
    // ceiling is what is left of the top half once the search row has taken its
    // share -- not the bottom half above the dock. X48's constraint is the one
    // that survives and it is the reason this cap exists at all: however many
    // results match, the strip and the tiles stay on screen.
    const float BUDGET = std::max(0.F, sc<float>(monitor->m_size.y) / 2.F - overviewSearchLogicalHeight(monitor));

    return std::min(panelH + (OVERVIEW_RESULT_PANELGAPL * 2.F), BUDGET);
}

// The tile currently being dragged. It gives up its grid slot for the duration
// so the survivors close the gap it left WHILE it travels -- F3-b-iii's "the
// windows already in the grid must be seen moving to make room", applied to a
// drag instead of a search (user request, 2026-08-02). Nothing else is needed:
// SGridReflow already eases every tile whose slot changed.
inline Desktop::View::CWindow* g_dragReflowExcluded = nullptr;

// ponytail: recomputed per window per frame, O(windows^2) on the focused
// workspace. Fine at desktop counts; memoise per frame if it ever shows up.
inline bool overviewGridLayout(const PHLWORKSPACE& workspace, PHLMONITOR monitor, const PHLWINDOW& target, CBox& out) {
    auto WINDOWS = overviewMainGridWindows(workspace, monitor);

    // The dragged window keeps a slot for its OWN query: the drag proxy is sized
    // off it, and a proxy sized from the N-1 layout would jump the frame the
    // drag begins. It is absent only from everyone else's layout.
    if (g_dragReflowExcluded && target.get() != g_dragReflowExcluded)
        std::erase_if(WINDOWS, [](const auto& window) { return window.get() == g_dragReflowExcluded; });

    const auto TARGETIT = std::ranges::find(WINDOWS, target);
    if (TARGETIT == WINDOWS.end())
        return false;

    CBox usable = {monitor->m_position, monitor->m_size};
    if (workspace->m_space) {
        if (const auto WORKAREA = workspace->m_space->workArea(); WORKAREA.w > 1 && WORKAREA.h > 1)
            usable = WORKAREA;
    }


    // Grid tiles must not slide under the strip band or the search row (X10) --
    // shrinking `usable` here is what makes the tiles compact to give the space
    // back.
    //
    // X60 SUPERSEDES X48's placement: the results are part of the TOP chrome
    // now, between the search row and the strip, so the whole stack below them
    // moves down and the tiles give their space back from the top. X21's reflow
    // is untouched -- the tiles still shrink and compact off the same eased
    // band, only the direction changed. X48's real constraint survives in
    // overviewResultsBandTarget's budget: the band may never grow so tall that
    // the strip and the tiles are pushed off the screen.
    if (const float TOPCHROME = overviewStripLogicalHeight(monitor) + overviewSearchLogicalHeight(monitor) + overviewResultsLogicalHeight(monitor); TOPCHROME > 0.F) {
        usable.y += TOPCHROME;
        usable.h -= TOPCHROME;
        if (usable.h <= 1)
            return false;
    }
    const size_t COUNT = WINDOWS.size();
    const float  GAP   = sc<float>(ScrollOverview::Config::getMissionControlGap());

    usable.x += GAP;
    usable.y += GAP;
    usable.w -= 2.0 * GAP;
    usable.h -= 2.0 * GAP;
    if (usable.w <= 1 || usable.h <= 1)
        return false;

    // Pick the row count that lets every window share the largest common scale.
    // Capped at 1.0 so a lone window keeps its real size instead of ballooning.
    size_t bestRows  = 0;
    float  bestScale = 0.F;
    for (size_t rows = 1; rows <= COUNT; ++rows) {
        const size_t COLS  = (COUNT + rows - 1) / rows;
        const float  CELLW = (sc<float>(usable.w) - GAP * sc<float>(COLS - 1)) / sc<float>(COLS);
        const float  CELLH = (sc<float>(usable.h) - GAP * sc<float>(rows - 1)) / sc<float>(rows);
        if (CELLW <= 1.F || CELLH <= 1.F)
            continue;

        float rowScale = 1.F;
        for (const auto& window : WINDOWS) {
            const auto SIZE = overviewGridWindowSize(window);
            if (SIZE.x <= 1 || SIZE.y <= 1)
                continue;

            rowScale = std::min({rowScale, CELLW / sc<float>(SIZE.x), CELLH / sc<float>(SIZE.y)});
        }

        if (rowScale > bestScale) {
            bestScale = rowScale;
            bestRows  = rows;
        }
    }

    if (bestRows == 0 || bestScale <= 0.F)
        return false;

    // Spread the windows over the rows as evenly as possible, earlier rows take
    // the remainder.
    const size_t BASE  = COUNT / bestRows;
    const size_t EXTRA = COUNT % bestRows;
    const size_t INDEX = sc<size_t>(std::distance(WINDOWS.begin(), TARGETIT));

    size_t row       = 0;
    size_t rowFirst  = 0;
    size_t rowCount  = 0;
    for (; row < bestRows; ++row) {
        rowCount = BASE + (row < EXTRA ? 1 : 0);
        if (INDEX < rowFirst + rowCount)
            break;

        rowFirst += rowCount;
    }

    if (row >= bestRows)
        return false;

    float rowWidth = GAP * sc<float>(rowCount - 1);
    for (size_t i = 0; i < rowCount; ++i)
        rowWidth += sc<float>(overviewGridWindowSize(WINDOWS[rowFirst + i]).x) * bestScale;

    float x = sc<float>(usable.x) + (sc<float>(usable.w) - rowWidth) / 2.F;
    for (size_t i = rowFirst; i < INDEX; ++i)
        x += sc<float>(overviewGridWindowSize(WINDOWS[i]).x) * bestScale + GAP;

    const auto  SIZE   = overviewGridWindowSize(target);
    const float WIDTH  = sc<float>(SIZE.x) * bestScale;
    const float HEIGHT = sc<float>(SIZE.y) * bestScale;
    const float CELLH  = (sc<float>(usable.h) - GAP * sc<float>(bestRows - 1)) / sc<float>(bestRows);
    const float Y      = sc<float>(usable.y) + sc<float>(row) * (CELLH + GAP) + (CELLH - HEIGHT) / 2.F;

    out = CBox{x, Y, WIDTH, HEIGHT};
    return true;
}

inline bool overviewGridSlot(const PHLWINDOW& window, PHLMONITOR monitor, CBox& out) {
    if (!ScrollOverview::Config::getMissionControl() || !monitor)
        return false;

    const auto WORKSPACE = window->m_workspace;
    if (!WORKSPACE)
        return false;

    // A promoted window is laid out in the ACTIVE workspace's grid, not its own.
    if (WORKSPACE != monitor->m_activeWorkspace && !overviewGridPromoted(window, monitor))
        return false;

    return overviewGridLayout(monitor->m_activeWorkspace, monitor, window, out);
}

// 0 while the overview is closed, 1 once it is fully open, so windows travel
// between their real rect and their grid slot instead of snapping.
inline float overviewGridProgress(float scale) {
    const float TARGET = ScrollOverview::Config::getScale();
    if (std::abs(1.F - TARGET) < 0.001F)
        return 1.F;

    return std::clamp((1.F - scale) / (1.F - TARGET), 0.F, 1.F);
}

inline CBox overviewGridLerpBox(const CBox& from, const CBox& to, float t) {
    return CBox{
        from.x + (to.x - from.x) * t,
        from.y + (to.y - from.y) * t,
        from.w + (to.w - from.w) * t,
        from.h + (to.h - from.h) * t,
    };
}

// The grid is recomputed from the live window list every frame, so a window
// joining or leaving the focused workspace would teleport every other tile
// straight to its new slot. Each window keeps its own reflow clock: when its
// target slot changes it travels there over mission_control_reflow_ms.
// OVERVIEW_CPP_SPEC B4 + user requirement U4.
struct SGridReflow {
    PHLWINDOWREF    window;
    CBox            from;
    CBox            to;
    Time::steady_tp start;
    uint64_t        lastFrame    = 0;
    bool            promotedLast = false;
};

inline std::unordered_map<Desktop::View::CWindow*, SGridReflow> g_gridReflows;
inline bool                                      g_gridReflowActive = false;

// A reflow is windows arriving at new slots, i.e. an entrance: house decel.
inline float gridReflowEase(float t) {
    return houseEase(true, t);
}

inline bool gridBoxesDiffer(const CBox& a, const CBox& b) {
    return std::abs(a.x - b.x) > 0.5 || std::abs(a.y - b.y) > 0.5 || std::abs(a.w - b.w) > 0.5 || std::abs(a.h - b.h) > 0.5;
}

// Called from getOverviewWindowBox, i.e. many times per window per frame from
// render, hit-test and drag alike. Restarting only when the *target* moves keeps
// it idempotent within a frame, so those call sites cannot disagree.
inline CBox gridReflowBox(const PHLWINDOW& window, const CBox& slot, const CBox* enterFrom = nullptr, bool promoted = false) {
    const int DURATION = ScrollOverview::Config::getMissionControlReflowMs();
    if (DURATION <= 0)
        return slot;

    const auto NOW = Time::steadyNow();

    if (g_gridReflows.size() > 64)
        std::erase_if(g_gridReflows, [](const auto& entry) { return !entry.second.window.lock(); });

    auto& entry = g_gridReflows[window.get()];

    // OVERVIEW_CPP_SPEC F3-b-i. A tile that was not in the grid last frame is
    // ENTERING now -- first appearance, or a search promoting it off another
    // desktop. Seeding from `slot` makes from == to and draws it straight at its
    // destination, which is exactly the "matches just spawn in" defect. Seed it
    // where it really sits and the ease below carries it in.
    //
    // Untouched-for-a-while stands in for "was not in the grid", so searching the
    // same window a second time re-enters properly instead of reusing its stale
    // settled entry. KNOWN == false also catches a recycled address handing a new
    // window a dead one's entry.
    const bool KNOWN = entry.window.lock() == window;
    // An entering tile is seeded off-screen on purpose, so it is culled -- and
    // on frames where that culls the whole workspace, its pass is skipped and
    // this function is not called at all. Reseeding then would throw away an
    // ease that is still running and draw the tile at its destination.
    const bool INFLIGHT = KNOWN && ScrollOverview::Config::animElapsedMs(entry.start) < sc<float>(DURATION);
    // Genuinely absent: a tile that stopped being drawn entirely, stayed gone
    // long enough to finish whatever it was doing, and is coming back.
    const bool UNDRAWN = KNOWN && !INFLIGHT && g_overviewFrame - entry.lastFrame > 1;
    // ...and the case staleness can never see, because the tile was on screen
    // the whole time: it just crossed onto the active card.
    const bool JOINED = KNOWN && promoted && !entry.promotedLast;

    if (!KNOWN || UNDRAWN || JOINED) {
        const CBox START = enterFrom ? *enterFrom : slot;
        entry            = SGridReflow{window, START, slot, NOW, g_overviewFrame, promoted};
        if (gridBoxesDiffer(START, slot))
            g_gridReflowActive = true;
        return START;
    }

    entry.lastFrame    = g_overviewFrame;
    entry.promotedLast = promoted;

    const float ELAPSED = ScrollOverview::Config::animElapsedMs(entry.start);
    const float T       = gridReflowEase(ELAPSED / sc<float>(DURATION));
    const CBox  CURRENT = overviewGridLerpBox(entry.from, entry.to, T);

    if (gridBoxesDiffer(slot, entry.to)) {
        entry.from  = CURRENT; // retarget from where the tile actually is
        entry.to    = slot;
        entry.start = NOW;
        g_gridReflowActive = true;
        return CURRENT;
    }

    if (T < 1.F)
        g_gridReflowActive = true;

    return CURRENT;
}

inline Vector2D axisOffsetVector(float offset, ScrollOverview::Config::ELayout layout);

inline CBox getOverviewBox(CBox box, PHLMONITOR monitor, float scale, const Vector2D& viewOffset, float offset, ScrollOverview::Config::ELayout layout,
                           bool round = true) {
    const auto MONITORSCALE    = monitor->m_scale;
    const auto VIEWPORT_CENTER = CBox{{}, monitor->m_size * MONITORSCALE}.middle();

    box = {box.pos() * MONITORSCALE, box.size() * MONITORSCALE};
    box.translate(-VIEWPORT_CENTER).scale(scale).translate(VIEWPORT_CENTER).translate(-viewOffset * scale * MONITORSCALE).translate(axisOffsetVector(offset, layout));
    if (round)
        box.round();

    return box;
}

inline CBox getOverviewGlobalBox(CBox globalBox, PHLMONITOR monitor, float scale, const Vector2D& viewOffset, float offset, ScrollOverview::Config::ELayout layout,
                                 bool round = true) {
    return getOverviewBox({globalBox.pos() - monitor->m_position, globalBox.size()}, monitor, scale, viewOffset, offset, layout, round);
}

// X22: the top chrome -- search pill, results panel, workspace strip -- is
// STATIC SCREEN FURNITURE. It goes through the SAME transform as the cards but
// with a zero view offset, so it keeps the open/close scale (and with it the
// inset from the monitor's top edge that keeps it clear of the layer-shell bar
// -- X10's occlusion finding stands) while refusing to pan with the desktops.
inline const Vector2D OVERVIEW_CHROME_NO_PAN = {};

inline CBox getOverviewWindowBox(const PHLWINDOW& window, PHLMONITOR monitor, float scale, const Vector2D& viewOffset, float offset, ScrollOverview::Config::ELayout layout,
                                 bool round = true, const CBox* geometryOverride = nullptr) {
    if (!window)
        return {};

    // OVERVIEW_CPP_SPEC 13.5 X17. geometryOverride lets a caller push a SNAPSHOT
    // of a window's desktop geometry through the grid transform below. Everything
    // the user can see or hit goes through this function; anything that maps raw
    // desktop geometry itself lands somewhere the tile is not.
    auto geometry = geometryOverride ? *geometryOverride : window->geometricBox(Desktop::View::IGeometric::GEOMETRIC_CURRENT);

    // F3-b outbound. It has just stopped matching, so it owns no slot and
    // overviewGridSlot says no, but it is still drawn on the active card for one
    // reflow. `geometry` already IS its real rect on its own desktop, so easing
    // to it means the frame the release expires draws the identical box down the
    // ordinary path below and the handover is invisible. The offset carries the
    // direction that desktop lies in, in RENDERED px against logical geometry,
    // hence the divide -- same conversion as the inbound seed.
    if (overviewGridReleasing(window, monitor)) {
        CBox home = geometry;
        if (const float UNIT = scale * std::max(monitor->m_scale, 0.01F); UNIT > 0.01F && std::abs(offset) > 0.01F)
            home.translate(axisOffsetVector(offset / UNIT, layout));

        geometry = overviewGridLerpBox(geometry, gridReflowBox(window, home, nullptr, false), overviewGridProgress(scale));
        offset   = 0.F;
    } else if (CBox slot; overviewGridSlot(window, monitor, slot)) {
        const bool PROMOTED = overviewGridPromoted(window, monitor);

        // F3-b-i: a promoted tile enters from the place it occupies on its own
        // desktop -- which is exactly the per-workspace offset suppressed below,
        // so it carries the direction that desktop lies in for free. That offset
        // is in RENDERED px while `slot` is logical, hence the divide.
        CBox        enterFrom;
        const CBox* enterPtr = nullptr;
        if (PROMOTED && std::abs(offset) > 0.01F) {
            if (const float UNIT = scale * std::max(monitor->m_scale, 0.01F); UNIT > 0.01F) {
                enterFrom = slot;
                enterFrom.translate(axisOffsetVector(offset / UNIT, layout));
                enterPtr = &enterFrom;
            }
        }

        geometry = overviewGridLerpBox(geometry, gridReflowBox(window, slot, enterPtr, PROMOTED), overviewGridProgress(scale));

        // The active card sits at offset 0. A promoted tile must ignore the
        // caller's per-workspace offset or it lands off-screen beside it.
        if (PROMOTED)
            offset = 0.F;
    }

    return getOverviewGlobalBox(geometry, monitor, scale, viewOffset, offset, layout, round);
}

inline CBox getOverviewDragWindowBox(const PHLWINDOW& window, PHLMONITOR monitor, float scale, const Vector2D& viewOffset, float offset, ScrollOverview::Config::ELayout layout,
                                     bool round = true) {
    if (!window)
        return {};

    const auto TARGET = window->layoutTarget();
    if (window->m_group && TARGET)
        return getOverviewGlobalBox(TARGET->position(), monitor, scale, viewOffset, offset, layout, round);

    return getOverviewWindowBox(window, monitor, scale, viewOffset, offset, layout, round);
}

inline CBox expandOverviewWindowHitbox(CBox box, float scale, float monitorScale) {
    const auto GAPS = ScrollOverview::Config::getCssGapData("general:gaps_in");
    constexpr float GAP_MULTIPLIER = 2.F;
    const float     TOTALSCALE     = scale * monitorScale;

    box.x -= sc<float>(std::max<int64_t>(0, GAPS.m_left)) * TOTALSCALE * GAP_MULTIPLIER;
    box.y -= sc<float>(std::max<int64_t>(0, GAPS.m_top)) * TOTALSCALE * GAP_MULTIPLIER;
    box.width += sc<float>(std::max<int64_t>(0, GAPS.m_left) + std::max<int64_t>(0, GAPS.m_right)) * TOTALSCALE * GAP_MULTIPLIER;
    box.height += sc<float>(std::max<int64_t>(0, GAPS.m_top) + std::max<int64_t>(0, GAPS.m_bottom)) * TOTALSCALE * GAP_MULTIPLIER;

    return box;
}

inline float overviewPointDistanceSqToBox(const Vector2D& point, const CBox& box) {
    const float dx = point.x < box.x ? box.x - point.x : point.x > box.x + box.width ? point.x - (box.x + box.width) : 0.F;
    const float dy = point.y < box.y ? box.y - point.y : point.y > box.y + box.height ? point.y - (box.y + box.height) : 0.F;

    return dx * dx + dy * dy;
}

inline Vector2D getOverviewMousePosLocal(PHLMONITOR monitor) {
    if (!monitor)
        return {};

    return (g_pInputManager->getMouseCoordsInternal() - monitor->m_position) * monitor->m_scale;
}

inline bool isOverviewPointerOnMonitor(PHLMONITOR monitor) {
    const auto overview = monitor ? scrollOverviewAt(g_pInputManager->getMouseCoordsInternal()) : SP<IOverview>{};
    return overview && overview->pMonitor.lock() == monitor;
}

inline Vector2D axisOffsetVector(float offset, ScrollOverview::Config::ELayout layout) {
    return layout == ScrollOverview::Config::ELayout::HORIZONTAL ? Vector2D{offset, 0.F} : Vector2D{0.F, offset};
}

inline float axisValue(const Vector2D& vector, ScrollOverview::Config::ELayout layout) {
    return layout == ScrollOverview::Config::ELayout::HORIZONTAL ? vector.x : vector.y;
}

inline float axisSize(const Vector2D& size, ScrollOverview::Config::ELayout layout) {
    return layout == ScrollOverview::Config::ELayout::HORIZONTAL ? size.x : size.y;
}

inline CBox getOverviewWorkspaceBox(PHLMONITOR monitor, float scale, const Vector2D& viewOffset, float offset, ScrollOverview::Config::ELayout layout) {
    return getOverviewBox({{}, monitor->m_size}, monitor, scale, viewOffset, offset, layout);
}

inline CBox getWorkspaceGlobalBox(PHLWORKSPACE workspace, PHLMONITOR fallbackMonitor) {
    const auto MONITOR = workspace && workspace->m_monitor ? workspace->m_monitor.lock() : fallbackMonitor;
    if (!MONITOR)
        return {};

    return {MONITOR->m_position, MONITOR->m_size};
}

inline CBox centerBoxInWorkspace(CBox box, PHLWORKSPACE workspace, PHLMONITOR fallbackMonitor) {
    const auto WORKSPACEBOX = getWorkspaceGlobalBox(workspace, fallbackMonitor);
    if (WORKSPACEBOX.width <= 0 || WORKSPACEBOX.height <= 0)
        return box;

    box.x = WORKSPACEBOX.x + std::max(0.F, sc<float>(WORKSPACEBOX.width - box.width)) / 2.F;
    box.y = WORKSPACEBOX.y + std::max(0.F, sc<float>(WORKSPACEBOX.height - box.height)) / 2.F;

    return box;
}

inline CBox clampBoxToWorkspace(CBox box, PHLWORKSPACE workspace, PHLMONITOR fallbackMonitor, float margin = 0.F) {
    const auto WORKSPACEBOX = getWorkspaceGlobalBox(workspace, fallbackMonitor);
    if (WORKSPACEBOX.width <= 0 || WORKSPACEBOX.height <= 0)
        return box;

    const float CLAMPMARGIN = std::max(0.F, margin);
    const float MINX        = WORKSPACEBOX.x + CLAMPMARGIN;
    const float MINY        = WORKSPACEBOX.y + CLAMPMARGIN;
    const float MAXX        = WORKSPACEBOX.x + std::max(0.F, sc<float>(WORKSPACEBOX.width - box.width - 2.F * CLAMPMARGIN)) + CLAMPMARGIN;
    const float MAXY        = WORKSPACEBOX.y + std::max(0.F, sc<float>(WORKSPACEBOX.height - box.height - 2.F * CLAMPMARGIN)) + CLAMPMARGIN;

    box.x = std::clamp(sc<float>(box.x), MINX, std::max(MINX, MAXX));
    box.y = std::clamp(sc<float>(box.y), MINY, std::max(MINY, MAXY));

    return box;
}

inline CBox resizedOverviewBoxFromCorner(const CBox& originalBox, const Vector2D& delta, Layout::eRectCorner corner, const Vector2D& minSizePx,
                                         const std::optional<Vector2D>& maxSizePx) {
    float left   = originalBox.x;
    float top    = originalBox.y;
    float right  = originalBox.x + originalBox.width;
    float bottom = originalBox.y + originalBox.height;

    switch (corner) {
        case Layout::CORNER_TOPLEFT:
            left += delta.x;
            top += delta.y;
            break;
        case Layout::CORNER_TOPRIGHT:
            right += delta.x;
            top += delta.y;
            break;
        case Layout::CORNER_BOTTOMLEFT:
            left += delta.x;
            bottom += delta.y;
            break;
        case Layout::CORNER_BOTTOMRIGHT:
        default:
            right += delta.x;
            bottom += delta.y;
            break;
    }

    float width  = right - left;
    float height = bottom - top;

    const float minWidth  = sc<float>(std::max(1.0, minSizePx.x));
    const float minHeight = sc<float>(std::max(1.0, minSizePx.y));
    const float maxWidth  = maxSizePx ? sc<float>(std::max(sc<double>(minWidth), maxSizePx->x)) : std::numeric_limits<float>::max();
    const float maxHeight = maxSizePx ? sc<float>(std::max(sc<double>(minHeight), maxSizePx->y)) : std::numeric_limits<float>::max();

    width  = std::clamp(width, minWidth, maxWidth);
    height = std::clamp(height, minHeight, maxHeight);

    switch (corner) {
        case Layout::CORNER_TOPLEFT:
            left = right - width;
            top  = bottom - height;
            break;
        case Layout::CORNER_TOPRIGHT:
            right = left + width;
            top   = bottom - height;
            break;
        case Layout::CORNER_BOTTOMLEFT:
            left   = right - width;
            bottom = top + height;
            break;
        case Layout::CORNER_BOTTOMRIGHT:
        default:
            right  = left + width;
            bottom = top + height;
            break;
    }

    return CBox{{left, top}, {right - left, bottom - top}};
}

inline CBox clampResizedOverviewBoxToWorkspace(const CBox& box, const CBox& workspaceBox, Layout::eRectCorner corner, float marginPx) {
    if (workspaceBox.width <= 0 || workspaceBox.height <= 0)
        return box;

    const float minX = workspaceBox.x + std::max(0.F, marginPx);
    const float minY = workspaceBox.y + std::max(0.F, marginPx);
    const float maxX = workspaceBox.x + workspaceBox.width - std::max(0.F, marginPx);
    const float maxY = workspaceBox.y + workspaceBox.height - std::max(0.F, marginPx);

    float left   = box.x;
    float top    = box.y;
    float right  = box.x + box.width;
    float bottom = box.y + box.height;

    switch (corner) {
        case Layout::CORNER_TOPLEFT:
            left = std::max(left, minX);
            top  = std::max(top, minY);
            break;
        case Layout::CORNER_TOPRIGHT:
            right = std::min(right, maxX);
            top   = std::max(top, minY);
            break;
        case Layout::CORNER_BOTTOMLEFT:
            left   = std::max(left, minX);
            bottom = std::min(bottom, maxY);
            break;
        case Layout::CORNER_BOTTOMRIGHT:
        default:
            right  = std::min(right, maxX);
            bottom = std::min(bottom, maxY);
            break;
    }

    return CBox{{left, top}, {right - left, bottom - top}};
}

inline bool overviewBoxIntersectsMonitor(const CBox& box, PHLMONITOR monitor) {
    if (!monitor || box.width <= 0 || box.height <= 0)
        return false;

    const auto RENDERSIZE = monitor->m_size * monitor->m_scale;

    return box.x < RENDERSIZE.x && box.x + box.width > 0 && box.y < RENDERSIZE.y && box.y + box.height > 0;
}

inline bool overviewBoxFullyVisibleOnMonitor(const CBox& box, PHLMONITOR monitor) {
    if (!monitor || box.empty())
        return false;

    const CBox VIEWPORT = {{}, monitor->m_size * monitor->m_scale};
    return box.x >= VIEWPORT.x && box.y >= VIEWPORT.y && box.x + box.width <= VIEWPORT.x + VIEWPORT.width && box.y + box.height <= VIEWPORT.y + VIEWPORT.height;
}

inline double overviewBoxIntersectionArea(const CBox& a, const CBox& b) {
    const auto INTERSECTION = a.intersection(b);
    return std::max(0.0, INTERSECTION.width) * std::max(0.0, INTERSECTION.height);
}

inline double overviewBoxArea(const CBox& box) {
    return std::max(0.0, box.width) * std::max(0.0, box.height);
}

inline double overviewBoxCenterDistanceSquared(const CBox& a, const CBox& b) {
    const auto ACENTER = a.middle();
    const auto BCENTER = b.middle();
    const auto DX      = ACENTER.x - BCENTER.x;
    const auto DY      = ACENTER.y - BCENTER.y;

    return DX * DX + DY * DY;
}

inline CBox getPinnedFloatingOverviewWindowBox(PHLMONITOR monitor, const PHLWINDOW& window, float targetOverviewScale, float animationProgress, float* renderScale) {
    if (!monitor || !window) {
        if (renderScale)
            *renderScale = 1.F;
        return {};
    }

    const auto MONITORSCALE = monitor->m_scale;
    const auto WINDOWSIZE   = window->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT) * MONITORSCALE;
    if (WINDOWSIZE.x <= 0 || WINDOWSIZE.y <= 0) {
        if (renderScale)
            *renderScale = 1.F;
        return {};
    }

    const CBox WINDOWBOX = {(window->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT) - monitor->m_position) * MONITORSCALE, WINDOWSIZE};
    const auto MONITORW  = sc<float>(monitor->m_size.x * MONITORSCALE);
    const auto MONITORH  = sc<float>(monitor->m_size.y * MONITORSCALE);

    const std::array<CBox, 4> QUADRANTS = {
        CBox{0.F, 0.F, MONITORW / 2.F, MONITORH / 2.F},
        CBox{MONITORW / 2.F, 0.F, MONITORW / 2.F, MONITORH / 2.F},
        CBox{0.F, MONITORH / 2.F, MONITORW / 2.F, MONITORH / 2.F},
        CBox{MONITORW / 2.F, MONITORH / 2.F, MONITORW / 2.F, MONITORH / 2.F},
    };

    size_t bestQuadrant = 0;
    double bestArea     = -1.0;
    for (size_t i = 0; i < QUADRANTS.size(); ++i) {
        const auto AREA = overviewBoxIntersectionArea(WINDOWBOX, QUADRANTS[i]);
        if (AREA <= bestArea)
            continue;

        bestQuadrant = i;
        bestArea     = AREA;
    }

    const bool RIGHT  = bestQuadrant == 1 || bestQuadrant == 3;
    const bool BOTTOM = bestQuadrant == 2 || bestQuadrant == 3;

    const auto FULLBOX = monitor->logicalBox();
    const auto WORKBOX = monitor->logicalBoxMinusReserved();

    const float RESERVEDLEFT   = std::max(0.F, sc<float>(WORKBOX.x - FULLBOX.x)) * MONITORSCALE;
    const float RESERVEDTOP    = std::max(0.F, sc<float>(WORKBOX.y - FULLBOX.y)) * MONITORSCALE;
    const float RESERVEDRIGHT  = std::max(0.F, sc<float>((FULLBOX.x + FULLBOX.width) - (WORKBOX.x + WORKBOX.width))) * MONITORSCALE;
    const float RESERVEDBOTTOM = std::max(0.F, sc<float>((FULLBOX.y + FULLBOX.height) - (WORKBOX.y + WORKBOX.height))) * MONITORSCALE;

    const auto WORKSPACEGAP       = sc<float>(ScrollOverview::Config::getWorkspaceGap()) * MONITORSCALE;
    const auto RESERVEDWIDTH      = RIGHT ? RESERVEDRIGHT : RESERVEDLEFT;
    const auto CALCULATEDWIDTH    = std::max(1.F, sc<float>((MONITORW - MONITORW * targetOverviewScale) / 2.F - 2.F * WORKSPACEGAP - RESERVEDWIDTH));
    const auto CALCULATEDSCALE    = CALCULATEDWIDTH / sc<float>(WINDOWSIZE.x);
    const auto WINDOWRENDERSCALE  = std::min(1.F, std::max(CALCULATEDSCALE, targetOverviewScale));
    const auto PROGRESS           = std::clamp(animationProgress, 0.F, 1.F);
    const auto CURRENTRENDERSCALE = 1.F + (WINDOWRENDERSCALE - 1.F) * PROGRESS;
    const auto TARGETWIDTH       = sc<float>(WINDOWSIZE.x) * CURRENTRENDERSCALE;
    const auto TARGETHEIGHT      = sc<float>(WINDOWSIZE.y) * CURRENTRENDERSCALE;

    if (renderScale)
        *renderScale = CURRENTRENDERSCALE;

    const float X = RIGHT ? MONITORW - TARGETWIDTH - WORKSPACEGAP - RESERVEDRIGHT : WORKSPACEGAP + RESERVEDLEFT;
    const float Y = BOTTOM ? MONITORH - TARGETHEIGHT - WORKSPACEGAP - RESERVEDBOTTOM : WORKSPACEGAP + RESERVEDTOP;

    CBox box = {{X, Y}, {TARGETWIDTH, TARGETHEIGHT}};

    box.x = WINDOWBOX.x + (box.x - WINDOWBOX.x) * PROGRESS;
    box.y = WINDOWBOX.y + (box.y - WINDOWBOX.y) * PROGRESS;
    box.round();

    return box;
}

inline std::chrono::milliseconds getOverviewIdleFrameInterval() {
    const int fps = std::clamp<int>(ScrollOverview::Config::getValue<int>("misc:render_unfocused_fps"), 1, 240);
    return std::chrono::milliseconds(std::max(1, 1000 / fps));
}

inline constexpr std::chrono::milliseconds OVERVIEW_WINDOW_FRAME_INTERVAL = std::chrono::milliseconds(33);

// Card shadow + corner-rounding helpers moved to OverviewChrome.hpp
// (included at the top of this file) so the dock can use them without
// pulling this whole header. They stay in namespace OvInternal.

inline float getWorkspaceRenderedPitch(PHLMONITOR monitor, float scale, ScrollOverview::Config::ELayout layout) {
    return (axisSize(monitor->m_size, layout) * scale + sc<float>(ScrollOverview::Config::getWorkspaceGap())) * monitor->m_scale;
}

inline float getWorkspaceLogicalPitch(PHLMONITOR monitor, float scale, ScrollOverview::Config::ELayout layout) {
    const auto safeScale = std::max(scale, 0.01F);
    return axisSize(monitor->m_size, layout) + sc<float>(ScrollOverview::Config::getWorkspaceGap()) / safeScale;
}

inline float getWindowVerticalOverlap(const PHLWINDOW& a, const PHLWINDOW& b) {
    if (!a || !b)
        return 0.F;

    const auto APOS  = a->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    const auto ASIZE = a->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    const auto BPOS  = b->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    const auto BSIZE = b->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT);

    const double overlap = std::min(APOS.y + ASIZE.y, BPOS.y + BSIZE.y) - std::max(APOS.y, BPOS.y);

    return std::max(0.F, sc<float>(overlap));
}

inline float getWindowHorizontalOverlap(const PHLWINDOW& a, const PHLWINDOW& b) {
    if (!a || !b)
        return 0.F;

    const auto APOS  = a->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    const auto ASIZE = a->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    const auto BPOS  = b->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    const auto BSIZE = b->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT);

    const double overlap = std::min(APOS.x + ASIZE.x, BPOS.x + BSIZE.x) - std::max(APOS.x, BPOS.x);

    return std::max(0.F, sc<float>(overlap));
}

inline bool overviewBoxesEqual(const CBox& a, const CBox& b) {
    return std::abs(a.x - b.x) < 0.5 && std::abs(a.y - b.y) < 0.5 && std::abs(a.width - b.width) < 0.5 && std::abs(a.height - b.height) < 0.5;
}

inline bool moveOverviewScrollingTargetToWorkspaceEdge(const SP<Layout::ITarget>& target, int side);
inline bool moveOverviewScrollingTargetNextToWindow(const SP<Layout::ITarget>& target, const PHLWINDOW& anchor, const std::string& direction);

inline double overviewTargetDirectionDelta(const SP<Layout::ITarget>& target, const PHLWINDOW& anchor, const std::string& direction) {
    if (!target || !anchor || !anchor->layoutTarget())
        return 0.0;

    const auto TARGETCENTER = target->position().middle();
    const auto ANCHORCENTER = anchor->layoutTarget()->position().middle();

    if (direction == "l" || direction == "r")
        return TARGETCENTER.x - ANCHORCENTER.x;

    return TARGETCENTER.y - ANCHORCENTER.y;
}

inline void moveOverviewTargetOneStep(const SP<Layout::ITarget>& target, const std::string& direction) {
    if (!target || direction.empty())
        return;

    g_layoutManager->moveInDirection(target, direction, true);
}

inline Layout::Tiled::CScrollingAlgorithm* overviewScrollingAlgorithmForTarget(const SP<Layout::ITarget>& target) {
    if (!target || !target->space() || !target->space()->algorithm())
        return nullptr;

    return dc<Layout::Tiled::CScrollingAlgorithm*>(target->space()->algorithm()->m_tiled.get());
}

inline Layout::Tiled::CScrollingAlgorithm* overviewScrollingAlgorithmForWorkspace(const PHLWORKSPACE& workspace) {
    if (!workspace || !workspace->m_space || !workspace->m_space->algorithm())
        return nullptr;

    return dc<Layout::Tiled::CScrollingAlgorithm*>(workspace->m_space->algorithm()->m_tiled.get());
}

inline bool isWorkspaceScrolling(const PHLWORKSPACE& workspace) {
    return overviewScrollingAlgorithmForWorkspace(workspace) != nullptr;
}

inline CBox getOverviewWorkspaceUsableBox(const PHLWORKSPACE& workspace, PHLMONITOR monitor, float scale, const Vector2D& viewOffset, float offset,
                                          ScrollOverview::Config::ELayout layout) {
    if (!workspace || !monitor)
        return {};

    if (const auto ALGO = overviewScrollingAlgorithmForWorkspace(workspace); ALGO && ALGO->m_scrollingData && ALGO->m_scrollingData->controller) {
        const auto USABLE = ALGO->usableArea();
        return getOverviewBox(USABLE, monitor, scale, viewOffset, offset, layout);
    }

    if (!workspace->m_space)
        return getOverviewWorkspaceBox(monitor, scale, viewOffset, offset, layout);

    auto USABLE = workspace->m_space->workArea();
    USABLE.translate(-monitor->m_position);
    USABLE.w = std::max(USABLE.w, 1.0);
    USABLE.h = std::max(USABLE.h, 1.0);

    return getOverviewBox(USABLE, monitor, scale, viewOffset, offset, layout);
}

inline double clampOverviewScrollingOffset(Layout::Tiled::CScrollingAlgorithm* algo, double offset) {
    if (!algo || !algo->m_scrollingData)
        return offset;

    const double MAXOFFSET = std::max(0.0, algo->m_scrollingData->maxWidth() - algo->primaryViewportSize());
    return std::clamp(offset, 0.0, MAXOFFSET);
}

inline bool moveOverviewScrollingTargetToWorkspaceEdge(const SP<Layout::ITarget>& target, int side) {
    if (!target || side == 0)
        return false;

    const auto ALGO = overviewScrollingAlgorithmForTarget(target);
    if (!ALGO || !ALGO->m_scrollingData)
        return false;

    const auto TDATA = ALGO->dataFor(target);
    if (!TDATA)
        return false;

    const auto SRC_COL = TDATA->column.lock();
    if (!SRC_COL)
        return false;

    const auto SRC_COL_WIDTH = SRC_COL->getColumnWidth();
    SRC_COL->remove(target);

    const int64_t INSERT_AFTER = side < 0 ? -1 : sc<int64_t>(ALGO->m_scrollingData->columns.size()) - 1;
    const auto    NEW_COL      = ALGO->m_scrollingData->add(INSERT_AFTER, SRC_COL_WIDTH);
    NEW_COL->add(TDATA);
    ALGO->m_scrollingData->centerOrFitCol(NEW_COL);
    ALGO->m_scrollingData->recalculate();
    ALGO->focusTargetUpdate(target);

    return true;
}

inline bool moveOverviewScrollingTargetNextToWindow(const SP<Layout::ITarget>& target, const PHLWINDOW& anchor, const std::string& direction) {
    if (!target || !anchor || !anchor->layoutTarget() || direction.empty())
        return false;

    const auto ALGO = overviewScrollingAlgorithmForTarget(target);
    if (!ALGO || !ALGO->m_scrollingData)
        return false;

    const auto TDATA      = ALGO->dataFor(target);
    const auto ANCHORDATA = ALGO->dataFor(anchor->layoutTarget());
    if (!TDATA || !ANCHORDATA)
        return false;

    const auto SRC_COL    = TDATA->column.lock();
    const auto ANCHOR_COL = ANCHORDATA->column.lock();
    if (!SRC_COL || !ANCHOR_COL)
        return false;

    const bool PRIMARYHORIZONTAL = ALGO->m_scrollingData->controller && ALGO->m_scrollingData->controller->isPrimaryHorizontal();
    const bool MOVINGCOLUMN      = PRIMARYHORIZONTAL ? direction == "l" || direction == "r" : direction == "u" || direction == "d";
    const bool STACKINGCOLUMN    = PRIMARYHORIZONTAL ? direction == "u" || direction == "d" : direction == "l" || direction == "r";

    if (MOVINGCOLUMN) {
        const auto SRC_COL_WIDTH = SRC_COL->getColumnWidth();
        SRC_COL->remove(target);

        const auto ANCHOR_COL_IDX = ALGO->m_scrollingData->idx(ANCHOR_COL);
        if (ANCHOR_COL_IDX < 0)
            return false;

        const bool    INSERT_BEFORE = direction == "l" || direction == "u";
        const int64_t INSERT_AFTER  = INSERT_BEFORE ? ANCHOR_COL_IDX - 1 : ANCHOR_COL_IDX;
        const auto    NEW_COL      = ALGO->m_scrollingData->add(INSERT_AFTER, SRC_COL_WIDTH);
        NEW_COL->add(TDATA);
        ALGO->m_scrollingData->centerOrFitCol(NEW_COL);
        ALGO->m_scrollingData->recalculate();
        ALGO->focusTargetUpdate(target);

        return true;
    }

    if (!STACKINGCOLUMN)
        return false;

    SRC_COL->remove(target);

    const auto ANCHOR_IDX    = ANCHOR_COL->idx(anchor->layoutTarget());
    const bool INSERT_BEFORE = direction == "l" || direction == "u";
    const int  INSERT_AFTER  = INSERT_BEFORE ? sc<int>(ANCHOR_IDX) - 1 : sc<int>(ANCHOR_IDX);
    ANCHOR_COL->add(TDATA, INSERT_AFTER);
    ALGO->m_scrollingData->centerOrFitCol(ANCHOR_COL);
    ALGO->m_scrollingData->recalculate();
    ALGO->focusTargetUpdate(target);

    return true;
}

inline void moveOverviewTargetNextToWindow(const SP<Layout::ITarget>& target, const PHLWINDOW& anchor, const std::string& direction) {
    if (!target || !anchor || direction.empty())
        return;

    if (moveOverviewScrollingTargetNextToWindow(target, anchor, direction))
        return;

    const auto PREVFALLBACK = ScrollOverview::Config::getValue<int>("binds:window_direction_monitor_fallback");
    ScrollOverview::Config::setValue("binds:window_direction_monitor_fallback", 0);
    auto restoreFallback   = Hyprutils::Utils::CScopeGuard([PREVFALLBACK] {
        ScrollOverview::Config::setValue("binds:window_direction_monitor_fallback", PREVFALLBACK);
    });

    const bool WANT_NEGATIVE = direction == "l" || direction == "u";
    const auto FORWARD       = direction;
    const auto BACKWARD      = direction == "l" ? "r" : direction == "r" ? "l" : direction == "u" ? "d" : "u";

    auto isDesiredSide = [&] {
        const auto DELTA = overviewTargetDirectionDelta(target, anchor, direction);
        return WANT_NEGATIVE ? DELTA < 0.0 : DELTA > 0.0;
    };

    for (size_t i = 0; i < 64 && isDesiredSide(); ++i) {
        const auto WORKSPACE = target->workspace();
        const auto BEFORE    = target->position();

        moveOverviewTargetOneStep(target, BACKWARD);

        if (target->workspace() != WORKSPACE || overviewBoxesEqual(BEFORE, target->position()))
            break;

        if (!isDesiredSide()) {
            moveOverviewTargetOneStep(target, FORWARD);
            return;
        }
    }

    for (size_t i = 0; i < 64 && !isDesiredSide(); ++i) {
        const auto WORKSPACE = target->workspace();
        const auto BEFORE    = target->position();

        moveOverviewTargetOneStep(target, FORWARD);

        if (target->workspace() != WORKSPACE || overviewBoxesEqual(BEFORE, target->position()))
            break;
    }
}

// X6: Hyprland's optimized blur FB is baked from the background+bottom pass, so
// it only ever holds the WALLPAPER -- never the overview backdrop, which this
// plugin draws later in its own pass. Layer-shell frost sampled from it is
// therefore stale the whole time the overview is open. Windows already dodge
// this via blockOverviewWindowBlurOptimization(); layers need the same.
// ponytail: blanket -- every top/overlay surface goes live for as long as the
// overview is open, measured +0.9pp GPU busy. If that ever matters, block only
// the surfaces whose box intersects the backdrop, or bake a second optimized FB
// that includes it instead of paying per-frame.
inline void blockOverviewLayerBlurOptimization(size_t firstElement) {
    if (!ScrollOverview::Config::getValue<bool>("plugin:scrolloverview:live_layer_frost"))
        return;

    auto& passElements = g_pHyprRenderer->m_renderPass.m_passElements;
    for (size_t i = firstElement; i < passElements.size(); ++i) {
        const auto& passElement = passElements[i];
        if (!passElement.element)
            continue;

        auto* surfacePassElement = dc<CSurfacePassElement*>(passElement.element.get());
        if (!surfacePassElement || !surfacePassElement->m_data.pLS)
            continue;

        surfacePassElement->m_data.blockBlurOptimization = true;
    }
}

inline void renderOverviewLayerLevel(PHLMONITOR monitor, uint32_t layer, const CBox& workspaceBox, float renderScale, const Time::steady_tp& now, float alpha = 1.F) {
    if (!monitor)
        return;

    bool pushedRenderHints = false;
    const bool MODULATEALPHA = alpha < 0.999F;

    for (auto const& ls : monitor->m_layerSurfaceLayers[layer]) {
        const auto LAYER = ls.lock();
        if (!Desktop::View::validMapped(LAYER))
            continue;

        if (!pushedRenderHints) {
            Render::SRenderModifData modif;
            modif.modifs.emplace_back(Render::SRenderModifData::RMOD_TYPE_SCALE, renderScale);
            modif.modifs.emplace_back(Render::SRenderModifData::RMOD_TYPE_TRANSLATE, workspaceBox.pos());

            g_pHyprRenderer->m_renderPass.add(makeUnique<CRendererHintsPassElement>(CRendererHintsPassElement::SData{.renderModif = modif}));
            pushedRenderHints = true;
        }

		auto& lsAlpha = LAYER->alpha()[Desktop::View::LS_ALPHA_FADE];
        float previousAlpha = 1.F;
        if (MODULATEALPHA && lsAlpha->value()) {
			previousAlpha = lsAlpha->value();
			lsAlpha->setValueAndWarp(previousAlpha * std::clamp(alpha, 0.F, 1.F));
		}

        g_pHyprRenderer->renderLayer(LAYER, monitor, now);

        if (MODULATEALPHA && lsAlpha->value())
			lsAlpha->setValueAndWarp(previousAlpha);
    }

    if (pushedRenderHints)
        g_pHyprRenderer->m_renderPass.add(makeUnique<CRendererHintsPassElement>(CRendererHintsPassElement::SData{.renderModif = Render::SRenderModifData{}}));
}

inline void focusOverviewFullscreenWindowIfActiveWorkspace(const PHLWINDOW& fullscreenWindow_, const PHLWORKSPACE& workspace, PHLMONITOR monitor) {
    const auto FULLSCREENWINDOW = getOverviewWindowToShow(fullscreenWindow_);

    if (!monitor || !workspace || workspace != monitor->m_activeWorkspace || !validMapped(FULLSCREENWINDOW) || FULLSCREENWINDOW->m_workspace != workspace)
        return;

    if (Desktop::focusState()->window() == FULLSCREENWINDOW)
        return;

    Desktop::focusState()->fullWindowFocus(FULLSCREENWINDOW, Desktop::FOCUS_REASON_DESKTOP_STATE_CHANGE, nullptr, true);
}

inline void syncWorkspaceGeometry(const PHLWORKSPACE& workspace) {
    if (!workspace || !workspace->m_space)
        return;

    for (const auto& targetRef : workspace->m_space->targets()) {
        const auto TARGET = targetRef.lock();
        if (TARGET)
            TARGET->warpPositionSize();
    }
}

inline PHLWINDOW getOverviewFullscreenVisibilityWindow(const PHLWORKSPACE& workspace, const PHLWINDOW& fallback) {
    const auto FULLSCREENWINDOW = workspace ? getOverviewWindowToShow(Fullscreen::controller()->getFullscreenWindow(workspace)) : PHLWINDOW{};

    if (shouldShowOverviewWindow(FULLSCREENWINDOW) && FULLSCREENWINDOW->m_workspace == workspace)
        return FULLSCREENWINDOW;

    return getOverviewWindowToShow(fallback);
}

inline float hyprlerp(const float& from, const float& to, const float perc) {
    return (to - from) * perc + from;
}

inline Vector2D hyprlerp(const Vector2D& from, const Vector2D& to, const float perc) {
    return Vector2D{hyprlerp(from.x, to.x, perc), hyprlerp(from.y, to.y, perc)};
}

} // namespace OvInternal

// The trailing `using namespace OvInternal;` used to live here so the moved code
// needed no edits -- but at file scope in a header it leaks the whole namespace
// into every TU that includes this. Each consumer opts in for itself now (right
// after the include), so a future includer decides its own qualification.

