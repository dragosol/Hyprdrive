#pragma once

#include "globals.hpp"
#include <hyprland/src/helpers/time/Time.hpp>

namespace OverviewWindow {

bool shouldBlurBackground(const PHLWINDOW& window);
bool shouldUsePrecomputedBlur(const PHLWINDOW& window, PHLMONITOR monitor = nullptr, const CBox* workspaceBox = nullptr, const CBox* windowBox = nullptr, bool dragged = false);
bool shouldUseBlurFramebuffer(const PHLWINDOW& window, PHLMONITOR monitor = nullptr, const CBox* workspaceBox = nullptr, const CBox* windowBox = nullptr);
void releaseTexturePrefilterCache();
void forceDecoRecalc(const PHLWINDOW& window);

struct SRenderParams {
    PHLMONITOR            monitor;
    PHLWINDOW             window;
    CBox                  windowBox;
    float                 renderScale          = 1.F;
    Time::steady_tp       now                  = {};
    const CBox*           workspaceBox         = nullptr;
    bool                  selected             = false;
    bool                  dragged              = false;
    // When true (overview tiles), decoration:blur:size is scaled by renderScale
    // for this draw only, and precomputed m_blurFB is NOT used so the desktop
    // blur FB cannot be rebuilt at the temporary strength. Dock previews set
    // false -- they must never touch global blur state.
    bool                  scaleBlurToRenderScale = true;
};

void renderOverviewWindow(const SRenderParams& params);

}
