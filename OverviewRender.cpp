#include "OverviewRender.hpp"
#include "OverviewPassElement.hpp"
#include <chrono>
#include <cmath>
#include <sstream>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>

namespace OverviewRender {

void flushPass(PHLMONITOR monitor) {
    if (!monitor || g_pHyprRenderer->m_renderPass.empty())
        return;

    g_pHyprRenderer->m_renderPass.render(CRegion{CBox{{}, monitor->m_transformedSize}});
    g_pHyprRenderer->m_renderPass.clear();
}

void queueBlur(const CBox& box, int rounding, float roundingPower, float alpha, bool usePrecomputedBlur) {
    if (alpha <= 0.F)
        return;

    if (box.empty())
        return;

    // X14: NOT a CRectPassElement. Upstream leaves a blurred rect's corners square
    // (see COverviewBlurPassElement::draw), so every frosted surface here -- strip
    // panel, workspace card, search pill -- leaked blur into its corner arcs.
    COverviewBlurPassElement::SData data;
    data.box           = box;
    data.rounding      = rounding;
    data.roundingPower = roundingPower;
    data.alpha         = alpha;
    data.xray          = usePrecomputedBlur;
    g_pHyprRenderer->m_renderPass.add(makeUnique<COverviewBlurPassElement>(data));
}

void renderBlur(PHLMONITOR monitor, const CBox& box, int rounding, float roundingPower, float alpha, bool usePrecomputedBlur) {
    if (!monitor)
        return;

    queueBlur(box, rounding, roundingPower, alpha, usePrecomputedBlur);
    flushPass(monitor);
}

}
