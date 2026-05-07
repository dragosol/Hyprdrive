#pragma once

#include "globals.hpp"
#include <hyprland/src/helpers/time/Time.hpp>

namespace OverviewWindow {

bool shouldBlurBackground(const PHLWINDOW& window);
bool shouldUsePrecomputedBlur(const PHLWINDOW& window);
bool shouldUseBlurFramebuffer(const PHLWINDOW& window);

struct SRenderParams {
    PHLMONITOR            monitor;
    PHLWINDOW             window;
    CBox                  windowBox;
    float                 renderScale        = 1.F;
    Time::steady_tp       now               = {};
    const CBox*           workspaceBox      = nullptr;
    bool                  usePrecomputedBlur = false;
    bool                  selected          = false;
};

void renderOverviewWindow(const SRenderParams& params);

}
