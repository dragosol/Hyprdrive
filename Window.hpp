#pragma once

#include "globals.hpp"
#include <hyprland/src/helpers/time/Time.hpp>

namespace OverviewWindow {

bool shouldBlurBackground(const PHLWINDOW& window);
bool shouldUsePrecomputedBlur(const PHLWINDOW& window, PHLMONITOR monitor = nullptr, const CBox* workspaceBox = nullptr, const CBox* windowBox = nullptr);
bool shouldUseBlurFramebuffer(const PHLWINDOW& window, PHLMONITOR monitor = nullptr, const CBox* workspaceBox = nullptr, const CBox* windowBox = nullptr);
void forceDecoRecalc(const PHLWINDOW& window);

struct SRenderParams {
    PHLMONITOR            monitor;
    PHLWINDOW             window;
    CBox                  windowBox;
    float                 renderScale        = 1.F;
    Time::steady_tp       now               = {};
    const CBox*           workspaceBox      = nullptr;
    bool                  selected          = false;
};

void renderOverviewWindow(const SRenderParams& params);

}
