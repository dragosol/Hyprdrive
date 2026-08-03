#include "Dock.hpp"

#include "AppSearch.hpp"
#include "Config.hpp"
#include "Minimize.hpp"
#include "OverviewRender.hpp"
#include "Window.hpp"

#include <algorithm>
#include <cmath>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#define private public
#define protected public
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
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
constexpr float ITEM_PAD_TOP    = 10.F;
constexpr float ITEM_PAD_BOTTOM = 14.F;
constexpr float ITEM_MARGIN_X   = 2.F;
constexpr float CONTAINER_PAD_X = 10.F;
constexpr float EDGE_MARGIN     = 4.F;

// X25. A preview is as TALL as an icon -- it shares the icon row -- and as wide
// as the window's own aspect makes it. The clamp is what stops one ultrawide or
// one tall-and-thin window from owning the pill; it is not a look, it is a
// bound, which is why it is a constant and not a config key.
constexpr float PREVIEW_MIN_ASPECT = 0.60F;
constexpr float PREVIEW_MAX_ASPECT = 2.20F;

constexpr const char* KEY_ENABLED    = "plugin:scrolloverview:dock:enabled";
constexpr const char* KEY_ICON_SIZE  = "plugin:scrolloverview:dock:icon_size";
constexpr const char* KEY_FRACTION   = "plugin:scrolloverview:dock:height_fraction";
constexpr const char* KEY_RADIUS     = "plugin:scrolloverview:dock:corner_radius";
constexpr const char* KEY_BG_COLOR   = "plugin:scrolloverview:dock:background_color";
constexpr const char* KEY_BG_OPACITY = "plugin:scrolloverview:dock:background_opacity";

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

void damageIfChanged(PHLMONITOR monitor) {
    if (!monitor)
        return;

    const auto  LAYOUT = layout(monitor);
    std::string signature;
    if (!LAYOUT.pill.empty()) {
        signature = std::to_string(sc<int>(LAYOUT.pill.x)) + "," + std::to_string(sc<int>(LAYOUT.pill.width));
        for (const auto& ITEM : LAYOUT.items)
            signature += "|" + ITEM.wmClass;
    }

    auto& LAST = g_signatures[monitor->m_id];
    if (LAST == signature)
        return;

    LAST = signature;
    g_pHyprRenderer->damageMonitor(monitor);
}

void render(PHLMONITOR monitor) {
    const auto LAYOUT = layout(monitor);
    if (LAYOUT.pill.empty())
        return;

    // X13: frost is always on. The reference's blur PARAMETERS (sigma 30,
    // brightness 0.60, live) are X29's job; this is the surface they land on.
    OverviewRender::queueBlur(LAYOUT.pill, LAYOUT.rounding, 2.F, 1.F, false);

    CRectPassElement::SRectData bg;
    bg.box           = LAYOUT.pill;
    bg.color         = background();
    bg.round         = LAYOUT.rounding;
    bg.roundingPower = 2.F;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(bg));

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

    if (LAYOUT.previews.empty())
        return;

    // X25. The REAL window, through the same path the overview tiles use --
    // which is the point of rebuilding the dock in C++ at all. An icon or a
    // cached screenshot here would be the defect the spec names.
    const auto NOW = Time::steadyNow();
    for (const auto& PREVIEW : LAYOUT.previews) {
        forcePreviewVisible(PREVIEW.window);

        const auto  SIZE        = PREVIEW.window->m_realSize->value();
        const float RENDERSCALE = SIZE.y >= 1.0 ? sc<float>(PREVIEW.box.height / (SIZE.y * monitor->m_scale)) : 1.F;

        OverviewWindow::renderOverviewWindow({
            .monitor     = monitor,
            .window      = PREVIEW.window,
            .windowBox   = PREVIEW.box,
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
