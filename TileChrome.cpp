#include "TileChrome.hpp"

#include "Config.hpp"
#include "globals.hpp"

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

// X7 asked for a "playful bouncy" blow-up borrowed from the deprecated
// overview's Easing.OutBack. **That clause is SUPERSEDED** by the standing
// Apple-motion rule and by the user's direct report on 2026-08-03 that the
// hover "is still bouncy and non-apple like". Zero overshoot now, both ways.
// Do NOT restore easeOutBack here as an X7 regression fix.
//
// Hover is a micro-interaction, so it sits in the rice's FAST family (150ms)
// rather than the 260ms entrance band; the exit is 27% quicker again.
constexpr float HOVER_GROW    = 0.05F;
constexpr float PRESS_SHRINK  = 0.04F;
constexpr float HOVER_IN_MS   = 150.F;
constexpr float HOVER_OUT_MS  = 110.F;
constexpr float PRESS_MS      = 90.F;

// X8 / close button proportions, as fractions of the tile's SHORT side so they
// stay put when the grid rescales, clamped so they stay legible in a 12-window
// grid and stop growing in a 1-window one.
constexpr float ICON_FRACTION   = 0.20F;
constexpr float ICON_MIN        = 28.F;
constexpr float ICON_MAX        = 72.F;
// X55. The host's `.window-close`, from gnome-shell-theme.gresource:
//     width/height 32, padding 3, StIcon icon-size 24, border-radius 999
//     background rgba(63,63,70,0.98), colour #fafafb, transition 100ms
// so the glyph is 24/32 = 0.75 of the button, and 32 is the CAP here rather
// than a fixed size -- the host's previews are always large, ours can be a
// twelfth of a screen, and a 32px button on a small tile would swallow it.
constexpr float CLOSE_FRACTION  = 0.15F;
constexpr float CLOSE_MIN       = 22.F;
constexpr float CLOSE_MAX       = 32.F;
// X55: ON the corner, not inside it. The host centres the button on the
// preview's top-right corner so it overhangs on both axes; this was 0.62
// button-diameters INWARD, which is the "inside corner" the user rejected.
constexpr float CLOSE_INSET     = 0.F;
constexpr float CLOSE_GLYPH     = 0.75F;

// The tile has to be most of the way hovered before the button appears, so a
// cursor crossing a tile on its way somewhere else does not strobe buttons.
constexpr float CLOSE_VISIBLE_AT = 0.55F;

// X57. The caption clears X8's app icon, which straddles the tile's bottom
// edge, and CAPTION_H is the plate's own height budget -- labelPill anchors by
// its BOTTOM, so this is what pushes it clear rather than over the icon.
constexpr float CAPTION_GAP = 6.F;
constexpr float CAPTION_H   = 40.F;

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

// Growing is an entrance and shrinking back is an exit, so the direction of the
// retarget picks the curve -- the same two the compositor and the shell use.
float eased(const SEase& ease) {
    const float PROGRESS = std::clamp(std::chrono::duration<float, std::milli>(Time::steadyNow() - ease.start).count() / ease.ms, 0.F, 1.F);
    const float CURVE    = houseEase(ease.to > ease.from, PROGRESS);

    return ease.from + (ease.to - ease.from) * CURVE;
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

    const float FACTOR = (1.F + HOVER_GROW * eased(STATE->hover)) * (1.F - PRESS_SHRINK * std::clamp(eased(STATE->press), 0.F, 1.F));
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

    if (std::clamp(eased(STATE->hover), 0.F, 1.F) < CLOSE_VISIBLE_AT)
        return {};

    const float SCALE = std::max(monitorScale, 0.01F);
    const float D     = std::clamp(shortSide(tileBox) * CLOSE_FRACTION, CLOSE_MIN * SCALE, CLOSE_MAX * SCALE);
    const float CX    = sc<float>(tileBox.x + tileBox.w) - D * CLOSE_INSET;
    const float CY    = sc<float>(tileBox.y) + D * CLOSE_INSET;
    // With CLOSE_INSET 0 those are exactly the tile's top-right corner, and the
    // box below is centred on it -- so it overhangs by D/2 on both axes.

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

    // X57. The tile's CAPTION -- the overview had none at all. Same pill as the
    // dock's tooltip, and it rides the hover ease so it fades in and out with
    // the tile rather than popping. Below the tile, clear of X8's app icon,
    // which straddles the bottom edge.
    if (const auto* const HSTATE = stateFor(window, false)) {
        const float A = std::clamp(eased(HSTATE->hover), 0.F, 1.F);
        if (A > 0.01F) {
            const float ICONSIDE = std::clamp(shortSide(tileBox) * ICON_FRACTION, ICON_MIN * SCALE, ICON_MAX * SCALE);
            const float BOTTOM   = sc<float>(tileBox.y + tileBox.h) + ICONSIDE / 2.F + CAPTION_GAP * SCALE;
            OverviewRender::labelPill(monitor, window->m_title, sc<float>(tileBox.x + tileBox.w / 2.0), BOTTOM + CAPTION_H * SCALE, A, SCALE);
        }
    }

    const auto BUTTON = closeButtonBox(window, tileBox, monitorScale);
    if (BUTTON.empty())
        return;

    // X55. It FADES rather than popping: the host transitions the button over
    // 100ms. Driven off the hover ramp above CLOSE_VISIBLE_AT, so it needs no
    // state of its own and cannot disagree with the threshold the hit-test uses.
    const auto* const CSTATE = stateFor(window, false);
    const float       ALPHA  = CSTATE ? std::clamp((eased(CSTATE->hover) - CLOSE_VISIBLE_AT) / (1.F - CLOSE_VISIBLE_AT), 0.F, 1.F) : 1.F;
    if (ALPHA <= 0.F)
        return;

    const int ROUND = sc<int>(std::round(BUTTON.w / 2.0));

    // X56. The RING is Hyprland's -- size from general:border_size, colour from
    // general:col.active_border -- the same source the tooltip and the drop
    // indicator read, so the button re-themes with everything else.
    const int BORDER = std::max(0, ScrollOverview::Config::getValue<int>("general:border_size"));
    if (BORDER > 0) {
        if (auto* const ACTIVE = sc<::Config::CGradientValueData*>(ScrollOverview::Config::valueRef<::Config::IComplexConfigValue>("general:col.active_border").ptr());
            ACTIVE && !ACTIVE->m_colors.empty()) {
            CRectPassElement::SRectData ring;
            ring.box           = BUTTON.copy().expand(sc<double>(BORDER) * SCALE);
            ring.color         = ACTIVE->m_colors[0].modifyA(ALPHA);
            ring.round         = ROUND + sc<int>(std::round(sc<float>(BORDER) * SCALE));
            ring.roundingPower = 2.F;
            g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(ring));
        }
    }

    // The DISC stays light, and that is a legibility constraint rather than a
    // taste one: the symbolic glyph ships as near-black artwork and this render
    // path cannot recolour a texture, so the host's dark disc would hide the X
    // completely. The host gets away with rgba(63,63,70,.98) because CSS
    // recolours its StIcon to #fafafb. Revisit if the glyph ever gets a tint.
    CRectPassElement::SRectData disc;
    disc.box           = BUTTON;
    disc.color         = CHyprColor{0.93F, 0.93F, 0.93F, 0.95F * ALPHA};
    disc.round         = ROUND;
    disc.roundingPower = 2.F;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(disc));

    if (const auto GLYPH = OverviewRender::appIcon(CLOSE_ICON)) {
        const float SIDE = sc<float>(BUTTON.w) * CLOSE_GLYPH;

        CTexPassElement::SRenderData x;
        x.tex = GLYPH;
        x.box = CBox{sc<float>(BUTTON.x + BUTTON.w / 2.0) - SIDE / 2.F, sc<float>(BUTTON.y + BUTTON.h / 2.0) - SIDE / 2.F, SIDE, SIDE};
        x.box.round();
        x.a = ALPHA;
        g_pHyprRenderer->m_renderPass.add(makeUnique<CTexPassElement>(x));
    }
}

}
