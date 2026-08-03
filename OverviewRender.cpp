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
#include "Config.hpp"
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
#include "globals.hpp"
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

    // X52 profile: split the COLD path three ways -- the icon-theme filesystem
    // walk, the decode/rasterise, and the texture upload -- because the fix for
    // each is a different fix.
    ++Prof::icoCold;
    const auto T0  = Prof::clock::now();
    auto       UP0 = T0;

    if (const auto PATH = AppSearch::resolveIconPath(iconName); !PATH.empty()) {
        const auto T1 = Prof::clock::now();
        Prof::icoResolveNs += std::chrono::duration_cast<std::chrono::nanoseconds>(T1 - T0).count();

        Hyprgraphics::CImage image(PATH, {OVERVIEW_APP_ICON_PX, OVERVIEW_APP_ICON_PX});
        const auto T2 = Prof::clock::now();
        Prof::icoDecodeNs += std::chrono::duration_cast<std::chrono::nanoseconds>(T2 - T1).count();
        UP0 = T2;
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

    Prof::icoUploadNs += std::chrono::duration_cast<std::chrono::nanoseconds>(Prof::clock::now() - UP0).count();

    g_overviewAppIcons[iconName] = texture;
    return texture;
}


// Everything renderText() varies its output on. Colour is in here because the
// same label is drawn selected and unselected, and those are different pixels.
struct STextKey {
    std::string str;
    std::string fontFamily;
    uint32_t    color  = 0;
    int         fontSize = 0;
    int         maxWidth = 0;
    int         weight   = 0;
    bool        italic   = false;

    bool        operator==(const STextKey&) const = default;
};

struct STextKeyHash {
    size_t operator()(const STextKey& k) const {
        size_t h = std::hash<std::string>{}(k.str);
        for (const size_t PART : {std::hash<std::string>{}(k.fontFamily), sc<size_t>(k.color), sc<size_t>(k.fontSize), sc<size_t>(k.maxWidth), sc<size_t>(k.weight),
                                  sc<size_t>(k.italic)})
            h ^= PART + 0x9e3779b9 + (h << 6) + (h >> 2);
        return h;
    }
};

static std::unordered_map<STextKey, SP<Render::ITexture>, STextKeyHash> g_textCache;

// A clock counts up, a search box fills a character at a time, a badge counts
// windows: the strings asked for are open-ended, so the cache needs a ceiling.
// Clearing wholesale rather than evicting by age keeps this to one branch --
// the entries are cheap to rebuild and the cap is far above a frame's worth.
static constexpr size_t TEXT_CACHE_MAX = 256;

SP<Render::ITexture> text(const std::string& str, const CHyprColor& color, int fontSize, bool italic, const std::string& fontFamily, int maxWidth, int weight) {
    if (str.empty())
        return nullptr;

    const STextKey KEY{.str        = str,
                       .fontFamily = fontFamily,
                       .color      = color.getAsHex(),
                       .fontSize   = fontSize,
                       .maxWidth   = maxWidth,
                       .weight     = weight,
                       .italic     = italic};

    if (const auto IT = g_textCache.find(KEY); IT != g_textCache.end())
        return IT->second;

    if (g_textCache.size() >= TEXT_CACHE_MAX)
        g_textCache.clear();

    auto texture = g_pHyprRenderer->renderText(str, color, fontSize, italic, fontFamily, maxWidth, weight);
    g_textCache.emplace(KEY, texture);
    return texture;
}

void clearTextCache() {
    g_textCache.clear();
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


// X57 / X56. Shape from the host, palette and border from Hyprland.
//
//   .dash-label, .window-caption {
//       background-color rgba(0,0,0,0.9); border 1px rgba(255,255,255,0.1);
//       border-radius 999px; padding 6px 12px; color #ffffff }
//
// The PILL and the 12x6 padding ratio are the host's; the SIZE is the user's
// ("make the tooltips bigger"); the BORDER is Hyprland's rather than that
// stylesheet's white-10%, per X56, so it re-themes with everything else.
namespace {
    constexpr float PILL_FONT  = 16.F;
    constexpr float PILL_PAD_X = 16.F;
    constexpr float PILL_PAD_Y = 9.F;
    constexpr float PILL_BG_A  = 0.90F;
}

CBox labelPill(PHLMONITOR monitor, const std::string& str, double cx, double bottomY, float alpha, float scale) {
    if (str.empty() || alpha <= 0.F || !monitor)
        return {};

    const float SCALE = std::max(scale, 0.01F);
    const auto  TEX   = text(str, CHyprColor{1.F, 1.F, 1.F, 1.F}, std::max(1, sc<int>(std::round(PILL_FONT * SCALE))), false, "", 0, 500);
    if (!TEX || !TEX->ok())
        return {};

    const float PADX = PILL_PAD_X * SCALE;
    const float PADY = PILL_PAD_Y * SCALE;
    const float W    = sc<float>(TEX->m_size.x) + 2.F * PADX;
    const float H    = sc<float>(TEX->m_size.y) + 2.F * PADY;

    CBox plate{std::round(sc<float>(cx) - W / 2.F), std::round(sc<float>(bottomY) - H), std::round(W), std::round(H)};
    // Keep it on screen: a tile or an icon at either end would otherwise push
    // its label off the edge.
    plate.x = std::clamp(plate.x, 0.0, std::max(0.0, monitor->m_size.x * SCALE - plate.width));

    // `border-radius: 999px` is a full pill, so the radius is half the height
    // rather than a constant -- it stays a pill when the font or padding moves.
    const int ROUND = sc<int>(std::round(plate.height / 2.0));

    const int BORDER = std::max(0, ScrollOverview::Config::getValue<int>("general:border_size"));
    if (BORDER > 0) {
        if (auto* const ACTIVE = sc<::Config::CGradientValueData*>(ScrollOverview::Config::valueRef<::Config::IComplexConfigValue>("general:col.active_border").ptr());
            ACTIVE && !ACTIVE->m_colors.empty()) {
            CRectPassElement::SRectData ring;
            ring.box           = plate.copy().expand(sc<double>(BORDER) * SCALE);
            ring.color         = ACTIVE->m_colors[0].modifyA(alpha);
            ring.round         = ROUND + sc<int>(std::round(sc<float>(BORDER) * SCALE));
            ring.roundingPower = 2.F;
            g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(ring));
        }
    }

    CRectPassElement::SRectData bg;
    bg.box           = plate;
    bg.color         = CHyprColor{0.F, 0.F, 0.F, PILL_BG_A * alpha};
    bg.round         = ROUND;
    bg.roundingPower = 2.F;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(bg));

    CTexPassElement::SRenderData label;
    label.tex = TEX;
    label.box = CBox{std::round(plate.x + PADX), std::round(plate.y + PADY), sc<float>(TEX->m_size.x), sc<float>(TEX->m_size.y)};
    label.a   = alpha;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CTexPassElement>(label));

    return plate;
}

}
