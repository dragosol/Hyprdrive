// See Genie.hpp.
#include <algorithm>
#include <any>
#include <cmath>
#include <functional>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "Genie.hpp"
#include "Config.hpp"

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/ClearPassElement.hpp>
#include <hyprland/src/render/pass/Pass.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
#include <hyprland/src/render/pass/TransformedWindowPassElement.hpp>
#include <hyprland/src/render/transformer/Transformer.hpp>

namespace ScrollOverview::Genie {
    namespace {
        // Strips about STRIP_PX render px tall: the sides are a staircase of
        // them, and at ~3 px the steps read as a curve.
        constexpr float STRIP_PX   = 3.F;
        constexpr int   STRIPS_MIN = 48;
        constexpr int   STRIPS_MAX = 480;
        // How far the bottom of the window leads the top: at LEAD the last
        // strip starts moving when the first is LEAD of the way in.
        constexpr float SLIDE_LEAD = 0.75F;
        constexpr float PINCH_LEAD = 0.9F;
        constexpr float FADE_FROM  = 0.82F; // the last stretch fades into the icon

        float smooth(float x) {
            x = std::clamp(x, 0.F, 1.F);
            return x * x * (3.F - 2.F * x);
        }

        class CGenieTransformer : public Render::IWindowTransformer {
          public:
            SP<Render::IFramebuffer> transform(SP<Render::IFramebuffer> in) override {
                const auto MONITOR = g_pHyprRenderer->m_renderData.pMonitor.lock();
                if (!m_active || !MONITOR || !in || !in->getTexture() || m_window.w < 2 || m_window.h < 2)
                    return in;
                const auto OUT = MONITOR->resources()->getUnusedWorkBuffer();
                if (!OUT)
                    return in;

                const auto     TEX  = in->getTexture();
                const Vector2D SIZE = TEX->m_size;
                if (SIZE.x < 1 || SIZE.y < 1)
                    return in;

                auto          guard = g_pHyprRenderer->bindTempFB(OUT);
                const CRegion ALL{0, 0, sc<int>(MONITOR->m_transformedSize.x), sc<int>(MONITOR->m_transformedSize.y)};
                g_pHyprRenderer->draw(CClearPassElement::SClearData{CHyprColor(0, 0, 0, 0)});

                const CBox& W = m_window;
                const CBox& I = m_icon;
                const float G = std::clamp(m_g, 0.F, 1.F);
                // The strip at height v (0 top, 1 bottom) of the window: where
                // its top edge is now, and how far its sides have pinched.
                const auto TOPY = [&](float v) {
                    const float S = smooth((G * (1.F + SLIDE_LEAD) - (1.F - v) * SLIDE_LEAD));
                    return (W.y + v * W.h) + ((I.y + v * I.h) - (W.y + v * W.h)) * S;
                };
                const auto PINCH = [&](float v) { return smooth((G * (1.F + PINCH_LEAD) - (1.F - v) * PINCH_LEAD) * 1.6F); };
                const float ALPHA = G <= FADE_FROM ? 1.F : 1.F - smooth((G - FADE_FROM) / (1.F - FADE_FROM));
                if (ALPHA <= 0.F)
                    return OUT;

                const int STRIPS = std::clamp(sc<int>(std::ceil(W.h / STRIP_PX)), STRIPS_MIN, STRIPS_MAX);
                for (int i = 0; i < STRIPS; ++i) {
                    const float V0 = sc<float>(i) / STRIPS, V1 = sc<float>(i + 1) / STRIPS, VM = (V0 + V1) / 2.F;
                    const float Y0 = TOPY(V0), Y1 = TOPY(V1);
                    const float Q  = PINCH(VM);
                    const float X0 = W.x + (I.x - W.x) * Q;
                    const float X1 = (W.x + W.w) + ((I.x + I.w) - (W.x + W.w)) * Q;
                    if (X1 - X0 < 0.5F || Y1 - Y0 < 0.05F)
                        continue;

                    // The strip's source rows, in the buffer's own UV.
                    g_pHyprRenderer->m_renderData.primarySurfaceUVTopLeft     = Vector2D{W.x / SIZE.x, (W.y + V0 * W.h) / SIZE.y};
                    g_pHyprRenderer->m_renderData.primarySurfaceUVBottomRight = Vector2D{(W.x + W.w) / SIZE.x, (W.y + V1 * W.h) / SIZE.y};
                    CTexPassElement::SRenderData strip;
                    strip.tex           = TEX;
                    // A hair taller than its slot so neighbours overlap: no seam
                    // of background between strips at fractional positions.
                    strip.box           = CBox{X0, Y0, X1 - X0, (Y1 - Y0) + 0.75F};
                    strip.a             = ALPHA;
                    strip.allowCustomUV = true;
                    g_pHyprRenderer->draw(strip, ALL);
                }
                g_pHyprRenderer->m_renderData.primarySurfaceUVTopLeft     = Vector2D(-1, -1);
                g_pHyprRenderer->m_renderData.primarySurfaceUVBottomRight = Vector2D(-1, -1);
                return OUT;
            }

            bool  m_active = false;
            CBox  m_window, m_icon; // monitor-local render px
            float m_g = 0.F;
        };

        CGenieTransformer* transformerOf(const PHLWINDOW& window) {
            if (!window)
                return nullptr;
            for (const auto& t : window->m_transformers)
                if (auto* G = dynamic_cast<CGenieTransformer*>(t.get()))
                    return G;
            return nullptr;
        }

        CGenieTransformer* ensure(const PHLWINDOW& window) {
            if (auto* G = transformerOf(window))
                return G;
            window->m_transformers.emplace_back(makeUnique<CGenieTransformer>());
            return dynamic_cast<CGenieTransformer*>(window->m_transformers.back().get());
        }

        void detach(const PHLWINDOW& window) {
            if (window)
                std::erase_if(window->m_transformers, [](const auto& t) { return dynamic_cast<CGenieTransformer*>(t.get()) != nullptr; });
        }

        void feed(CGenieTransformer* t, const CBox& windowBox, const CBox& iconBox, float g) {
            t->m_active = true;
            t->m_window = windowBox;
            t->m_icon   = iconBox;
            t->m_g      = g;
        }
    }

    // FORCED OFF (user, 2026-10-17: "genie minimize is broken ... keep it
    // forced off"). The key stays registered so a config that sets it still
    // loads; the settings row is labelled broken and cannot be switched on.
    bool enabled() {
        return false;
    }

    void drawProxy(PHLMONITOR monitor, const PHLWINDOW& window, const CBox& windowBox, const CBox& iconBox, float g, const std::function<void()>& drawAtWindow) {
        if (!monitor || !window)
            return;
        feed(ensure(window), windowBox, iconBox, g);

        auto nested = makeUnique<Render::CRenderPass>();
        {
            auto restore = g_pHyprRenderer->redirectPass(nested.get());
            drawAtWindow();
        }
        if (nested->empty())
            return;

        const double SCALE = std::max(monitor->m_scale, 0.01F);
        g_pHyprRenderer->addPassElement(makeUnique<CTransformedWindowPassElement>(CTransformedWindowPassElement::SData{
            .pass       = std::move(nested),
            .window     = window,
            .currentBox = windowBox.copy().scale(1.0 / SCALE),
            .blurBox    = windowBox.copy().round(),
            .blur       = false,
        }));
    }

    void driveReal(PHLMONITOR monitor, const PHLWINDOW& window, const CBox& windowBox, const CBox& iconBox, float g) {
        if (!monitor || !window)
            return;
        feed(ensure(window), windowBox, iconBox, g);
    }

    void sweep(const std::function<bool(const PHLWINDOW&)>& stillFlying) {
        for (const auto& W : Desktop::windowState()->windows())
            if (W && transformerOf(W) && !stillFlying(W))
                detach(W);
    }

    void shutdown() {
        for (const auto& W : Desktop::windowState()->windows())
            detach(W);
    }
}
