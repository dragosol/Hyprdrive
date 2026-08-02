#include "OverviewRender.hpp"
#include "OverviewPassElement.hpp"
#include <chrono>
#include <cmath>
#include <sstream>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/render/gl/GLTexture.hpp>
#include <drm_fourcc.h>
#include <hyprgraphics/image/Image.hpp>
#include "AppSearch.hpp"
#include <string>
#include <unordered_map>

namespace OverviewRender {

// Decode size for app icons. SVG rasterises at whatever size it is asked for,
// so this is picked once, generously, and scaled down when drawn -- the row
// height changes with the card transform and re-decoding per frame would be
// absurd.
static constexpr int OVERVIEW_APP_ICON_PX = 64;

// Icon name -> texture, built once. NULL entries are cached too: an icon that
// failed to resolve must not be re-searched on every single frame.
static std::unordered_map<std::string, SP<Render::ITexture>> g_overviewAppIcons;

SP<Render::ITexture> appIcon(const std::string& iconName) {
    if (iconName.empty())
        return nullptr;

    if (const auto IT = g_overviewAppIcons.find(iconName); IT != g_overviewAppIcons.end())
        return IT->second;

    SP<Render::ITexture> texture;

    if (const auto PATH = AppSearch::resolveIconPath(iconName); !PATH.empty()) {
        Hyprgraphics::CImage image(PATH, {OVERVIEW_APP_ICON_PX, OVERVIEW_APP_ICON_PX});
        if (image.success()) {
            if (const auto SURFACE = image.cairoSurface(); SURFACE && SURFACE->cairo()) {
                auto* const CAIRO = SURFACE->cairo();
                cairo_surface_flush(CAIRO);

                auto* const   DATA   = cairo_image_surface_get_data(CAIRO);
                const int     W      = cairo_image_surface_get_width(CAIRO);
                const int     H      = cairo_image_surface_get_height(CAIRO);
                const int     STRIDE = cairo_image_surface_get_stride(CAIRO);
                // cairo hands back premultiplied BGRA on little-endian, which is
                // what ARGB8888 means to DRM. RGB24 surfaces carry no alpha.
                const uint32_t FORMAT = cairo_image_surface_get_format(CAIRO) == CAIRO_FORMAT_RGB24 ? DRM_FORMAT_XRGB8888 : DRM_FORMAT_ARGB8888;

                if (DATA && W > 0 && H > 0)
                    texture = makeShared<Render::GL::CGLTexture>(FORMAT, DATA, sc<uint32_t>(STRIDE), Vector2D{sc<double>(W), sc<double>(H)});
            }
        }
    }

    g_overviewAppIcons[iconName] = texture;
    return texture;
}


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
