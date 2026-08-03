#include "TileChrome.hpp"

#include "AppSearch.hpp"
#include "OverviewRender.hpp"

#include <algorithm>
#include <cmath>
#include <unordered_map>

#include <hyprland/src/helpers/time/Time.hpp>

#define private public
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
#undef private

namespace ScrollOverview::TileChrome {

namespace {

// X7. The blow-up overshoots and settles -- that is the "playful bouncy" the
// user asked for and the Easing.OutBack the deprecated overview used. The press
// shrink does NOT overshoot: a bounce under the finger reads as a misclick.
constexpr float HOVER_GROW    = 0.05F;
constexpr float PRESS_SHRINK  = 0.04F;
constexpr float HOVER_IN_MS   = 220.F;
constexpr float HOVER_OUT_MS  = 140.F;
constexpr float PRESS_MS      = 90.F;

// X8 / close button proportions, as fractions of the tile's SHORT side so they
// stay put when the grid rescales, clamped so they stay legible in a 12-window
// grid and stop growing in a 1-window one.
constexpr float ICON_FRACTION   = 0.20F;
constexpr float ICON_MIN        = 28.F;
constexpr float ICON_MAX        = 72.F;
constexpr float CLOSE_FRACTION  = 0.15F;
constexpr float CLOSE_MIN       = 22.F;
constexpr float CLOSE_MAX       = 38.F;
// The button's centre, in button-diameters in from the tile's top-right corner.
constexpr float CLOSE_INSET     = 0.62F;
constexpr float CLOSE_GLYPH     = 0.55F;

// The tile has to be most of the way hovered before the button appears, so a
// cursor crossing a tile on its way somewhere else does not strobe buttons.
constexpr float CLOSE_VISIBLE_AT = 0.55F;

constexpr const char* CLOSE_ICON = "window-close-symbolic";

struct SEase {
    float           from  = 0.F;
    float           to    = 0.F;
    float           ms    = 1.F;
    Time::steady_tp start = {};

    float value() const {
        const float ELAPSED = std::chrono::duration<float, std::milli>(Time::steadyNow() - start).count();
        return ELAPSED >= ms ? to : from + (to - from) * (ELAPSED / ms);
    }

    bool running() const { return std::chrono::duration<float, std::milli>(Time::steadyNow() - start).count() < ms; }

    void retarget(float target, float durationMs) {
        if (std::abs(to - target) < 0.001F)
            return;

        from  = value();
        to    = target;
        ms    = std::max(1.F, durationMs);
        start = Time::steadyNow();
    }
};

struct SState {
    SEase hover;
    SEase press;
};

std::unordered_map<Desktop::View::CWindow*, SState> g_states;
PHLWINDOWREF                                        g_hovered;
PHLWINDOWREF                                        g_pressed;

// https://easings.net/#easeOutBack. Overshoots ~10% then settles.
float easeOutBack(float t) {
    constexpr float C1 = 1.70158F;
    constexpr float C3 = C1 + 1.F;

    const float X = std::clamp(t, 0.F, 1.F) - 1.F;
    return 1.F + C3 * X * X * X + C1 * X * X;
}

float easeOutCubic(float t) {
    const float INV = 1.F - std::clamp(t, 0.F, 1.F);
    return 1.F - INV * INV * INV;
}

SState* stateFor(const PHLWINDOW& window, bool create) {
    if (!window)
        return nullptr;

    // ponytail: only ever as many entries as tiles the cursor has touched this
    // session, and forget() empties it when the overview closes. Reaping dead
    // windows would need a hook for a map that never gets big.
    if (const auto IT = g_states.find(window.get()); IT != g_states.end())
        return &IT->second;

    return create ? &g_states[window.get()] : nullptr;
}

// Hover in and out use different curves: OutBack coming in (the bounce), plain
// cubic going out, because a bounce on the way out reads as the tile refusing
// to let go.
float hoverEased(const SState& state) {
    const float PROGRESS = std::clamp(std::chrono::duration<float, std::milli>(Time::steadyNow() - state.hover.start).count() / state.hover.ms, 0.F, 1.F);
    const float CURVE    = state.hover.to > state.hover.from ? easeOutBack(PROGRESS) : easeOutCubic(PROGRESS);

    return state.hover.from + (state.hover.to - state.hover.from) * CURVE;
}

float shortSide(const CBox& box) {
    return sc<float>(std::min(box.w, box.h));
}

}

void setHovered(const PHLWINDOW& window) {
    if (g_hovered.lock() == window)
        return;

    if (auto* const PREV = stateFor(g_hovered.lock(), false))
        PREV->hover.retarget(0.F, HOVER_OUT_MS);

    g_hovered = window;

    if (auto* const STATE = stateFor(window, true))
        STATE->hover.retarget(1.F, HOVER_IN_MS);
}

void setPressed(const PHLWINDOW& window, bool down) {
    if (!down) {
        if (auto* const STATE = stateFor(g_pressed.lock(), false))
            STATE->press.retarget(0.F, PRESS_MS);

        g_pressed.reset();
        return;
    }

    if (!window)
        return;

    g_pressed = window;
    if (auto* const STATE = stateFor(window, true))
        STATE->press.retarget(1.F, PRESS_MS);
}

void forget() {
    g_states.clear();
    g_hovered.reset();
    g_pressed.reset();
}

PHLWINDOW hovered() {
    return g_hovered.lock();
}

bool animating() {
    return std::ranges::any_of(g_states, [](const auto& entry) { return entry.second.hover.running() || entry.second.press.running(); });
}

CBox scaledBox(const PHLWINDOW& window, const CBox& base) {
    const auto* const STATE = stateFor(window, false);
    if (!STATE || base.w < 1 || base.h < 1)
        return base;

    const float FACTOR = (1.F + HOVER_GROW * hoverEased(*STATE)) * (1.F - PRESS_SHRINK * std::clamp(STATE->press.value(), 0.F, 1.F));
    if (std::abs(FACTOR - 1.F) < 0.0005F)
        return base;

    const float DW = sc<float>(base.w) * (FACTOR - 1.F);
    const float DH = sc<float>(base.h) * (FACTOR - 1.F);

    return CBox{base.x - DW / 2.F, base.y - DH / 2.F, base.w + DW, base.h + DH};
}

CBox closeButtonBox(const PHLWINDOW& window, const CBox& tileBox, float monitorScale) {
    const auto* const STATE = stateFor(window, false);
    if (!STATE || tileBox.w < 1 || tileBox.h < 1)
        return {};

    if (std::clamp(STATE->hover.value(), 0.F, 1.F) < CLOSE_VISIBLE_AT)
        return {};

    const float SCALE = std::max(monitorScale, 0.01F);
    const float D     = std::clamp(shortSide(tileBox) * CLOSE_FRACTION, CLOSE_MIN * SCALE, CLOSE_MAX * SCALE);
    const float CX    = sc<float>(tileBox.x + tileBox.w) - D * CLOSE_INSET;
    const float CY    = sc<float>(tileBox.y) + D * CLOSE_INSET;

    return CBox{CX - D / 2.F, CY - D / 2.F, D, D};
}

void render(PHLMONITOR monitor, const PHLWINDOW& window, const CBox& tileBox, float monitorScale) {
    if (!monitor || !window || tileBox.w < 1 || tileBox.h < 1)
        return;

    const float SCALE = std::max(monitorScale, 0.01F);

    // X8. GNOME's overview straddles the icon on the preview's BOTTOM edge --
    // the user's words were "little icons under the windows" -- rather than the
    // deprecated overview's top-left inset. Centred, so it reads as a label for
    // the tile rather than as part of its content.
    if (const auto TEX = OverviewRender::appIcon(AppSearch::iconForClass(window->m_class))) {
        const float SIDE = std::clamp(shortSide(tileBox) * ICON_FRACTION, ICON_MIN * SCALE, ICON_MAX * SCALE);

        CTexPassElement::SRenderData icon;
        icon.tex = TEX;
        icon.box = CBox{sc<float>(tileBox.x + tileBox.w / 2.0) - SIDE / 2.F, sc<float>(tileBox.y + tileBox.h) - SIDE / 2.F, SIDE, SIDE};
        icon.box.round();
        icon.a = 1.F;
        g_pHyprRenderer->m_renderPass.add(makeUnique<CTexPassElement>(icon));
    }

    const auto BUTTON = closeButtonBox(window, tileBox, monitorScale);
    if (BUTTON.empty())
        return;

    // A LIGHT disc with the dark symbolic glyph on top. The other way round is
    // what the theme's own colours suggest and it is invisible: symbolic icons
    // ship as near-black artwork, so a dark disc hides the X completely.
    CRectPassElement::SRectData disc;
    disc.box           = BUTTON;
    disc.color         = CHyprColor{0.93F, 0.93F, 0.93F, 0.95F};
    disc.round         = sc<int>(std::round(BUTTON.w / 2.0));
    disc.roundingPower = 2.F;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(disc));

    if (const auto GLYPH = OverviewRender::appIcon(CLOSE_ICON)) {
        const float SIDE = sc<float>(BUTTON.w) * CLOSE_GLYPH;

        CTexPassElement::SRenderData x;
        x.tex = GLYPH;
        x.box = CBox{sc<float>(BUTTON.x + BUTTON.w / 2.0) - SIDE / 2.F, sc<float>(BUTTON.y + BUTTON.h / 2.0) - SIDE / 2.F, SIDE, SIDE};
        x.box.round();
        x.a = 1.F;
        g_pHyprRenderer->m_renderPass.add(makeUnique<CTexPassElement>(x));
    }
}

}
