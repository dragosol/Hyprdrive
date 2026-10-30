#pragma once

#include "globals.hpp"

#include <cstddef>

// A CANVAS WINDOW HALF IN VIEW, CLIPPED TO ITS SLIDING DESKTOP (Mosaic.hpp
// slideClip; user, 2026-10-29: windows out of view "are visible in the
// desktop I swipe to until I let go of the trackpad"). main.cpp's renderWindow
// hook marks the pass before Hyprland queues the window and clips what it
// queued after: the surfaces by their own clip box, the shadow and border by
// the renderer's clip, set and cleared around them.
namespace ScrollOverview::MosaicSlide {
    size_t mark();
    // `clip`: monitor-local device px.
    void clip(const PHLWINDOW& w, const CBox& clip, size_t first);
}
