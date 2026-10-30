#include "MosaicSlide.hpp"

#include <memory>
#include <vector>

#define private public
#define protected public
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/Pass.hpp>
#include <hyprland/src/render/pass/SurfacePassElement.hpp>
#undef protected
#undef private

namespace ScrollOverview::MosaicSlide {
    namespace {
        // Sets (or clears) the renderer's clip box when the pass reaches it:
        // the border and the shadow read it as they draw, and a surface resets
        // it to nothing after itself.
        class CClipPassElement : public IPassElement {
          public:
            explicit CClipPassElement(const CBox& box) : m_box(box) {}
            std::vector<UP<IPassElement>> draw() override {
                g_pHyprRenderer->m_renderData.clipBox = m_box;
                return {};
            }
            bool needsLiveBlur() override {
                return false;
            }
            bool needsPrecomputeBlur() override {
                return false;
            }
            const char* passName() override {
                return "CHyprdriveSlideClip";
            }
            ePassElementType type() override {
                return EK_CUSTOM;
            }
            bool undiscardable() override {
                return true;
            }
            bool disableSimplification() override {
                return true;
            }

          private:
            CBox m_box;
        };
    }

    size_t mark() {
        return g_pHyprRenderer->currentPass().m_passElements.size();
    }

    void clip(const PHLWINDOW& w, const CBox& clip, size_t first) {
        auto& EL = g_pHyprRenderer->currentPass().m_passElements;
        if (first >= EL.size())
            return;
        bool wrapped = false;
        for (size_t i = first; i < EL.size(); ++i) {
            auto* E = EL[i].element.get();
            if (!E)
                continue;
            if (E->type() == EK_SURFACE) {
                auto* S = sc<CSurfacePassElement*>(E);
                if (S->m_data.pWindow != w)
                    continue;
                S->m_data.clipBox = S->m_data.clipBox.empty() ? clip : S->m_data.clipBox.intersection(clip);
                if (S->m_data.clipBox.empty()) // nothing of it on the desktop: draw nothing
                    S->m_data.clipBox = CBox{clip.x, clip.y, 0.5, 0.5};
                continue;
            }
            // Anything else the window queued (shadow, border): under the clip.
            EL.insert(EL.begin() + i, Render::CRenderPass::SPassElementData{.element = makeUnique<CClipPassElement>(clip)});
            ++i;
            wrapped = true;
        }
        if (wrapped)
            EL.push_back(Render::CRenderPass::SPassElementData{.element = makeUnique<CClipPassElement>(CBox{})});
    }
}
