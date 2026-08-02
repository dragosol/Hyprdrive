#include "Dock.hpp"

#include "AppSearch.hpp"
#include "Config.hpp"
#include "OverviewRender.hpp"

#include <algorithm>
#include <cmath>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#define private public
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
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
SMetrics metrics(size_t count, float iconMax, float maxWidth) {
    if (count == 0)
        return {};

    const float N     = sc<float>(count);
    const float CHROME = 2.F * CONTAINER_PAD_X + 2.F * ITEM_MARGIN_X * N;
    const float AVAIL  = maxWidth - CHROME;

    SMetrics out;
    out.icon   = std::max(8.F, std::min(iconMax, AVAIL / N));
    out.width  = CHROME + out.icon * N;
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

CHyprColor background() {
    // D2D `transparency-mode` FIXED with `custom-background-color`: the hue and
    // the alpha are two independent settings, so the key's own alpha is ignored.
    const auto     OPACITY = std::clamp(Config::getValue<float>(KEY_BG_OPACITY), 0.F, 1.F);
    const uint32_t ARGB    = Config::getValue<uint32_t>(KEY_BG_COLOR);

    return CHyprColor{sc<float>((ARGB >> 16) & 0xFF) / 255.F, sc<float>((ARGB >> 8) & 0xFF) / 255.F, sc<float>(ARGB & 0xFF) / 255.F, OPACITY};
}

std::unordered_map<MONITORID, std::string> g_signatures;

}

SLayout layout(PHLMONITOR monitor) {
    SLayout out;

    if (!monitor || !Config::getValue<bool>(KEY_ENABLED) || monitor->m_size.x < 1 || monitor->m_size.y < 1)
        return out;

    const auto CLASSES = runningClasses();
    if (CLASSES.empty())
        return out;

    const float SCALE    = std::max(monitor->m_scale, 0.01F);
    const float ICONMAX  = sc<float>(std::clamp(Config::getValue<int>(KEY_ICON_SIZE), 8, 512));
    const float FRACTION = std::clamp(Config::getValue<float>(KEY_FRACTION), 0.05F, 1.F);
    const auto  M        = metrics(CLASSES.size(), ICONMAX, FRACTION * sc<float>(monitor->m_size.x));

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

    return out;
}

// ponytail: the pill is static furniture, so it only needs damage when it
// changes shape -- an app opening or closing. X25's live previews will need
// per-frame damage of their own; that is the point at which this gets less
// lazy, not before.
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
}

}

// The runnable check for X27 is scripts/x27_gate.py: it measures the pill that
// actually landed on screen against the reference numbers. A pure-math assert
// was considered and dropped -- it would have had to link the whole plugin, and
// the proportions are exactly the thing a pixel measurement proves better.
