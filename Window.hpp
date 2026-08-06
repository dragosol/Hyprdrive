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
    // Dock hover panel: render a scaled copy via renderModif WITHOUT rewriting
    // m_realPosition/m_realSize. Mutating geometry left a mini rounded outline
    // at the real window's top-left (tiled position ignores the temp position
    // write; size still shrank).
    bool                  dockLivePreview        = false;
    // Y5. The minimize/restore fade, applied AT RENDER TIME. It deliberately
    // does NOT touch the window's own alpha animation: warping that mutates
    // real compositor state, which outlives the draw and leaks a half-faded
    // window if the flight is ever interrupted. fadeAlpha is the same lever
    // Hyprland's own window fades use.
    float                 alpha                  = 1.F;
};

void renderOverviewWindow(const SRenderParams& params);

}
