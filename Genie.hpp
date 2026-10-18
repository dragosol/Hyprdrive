#pragma once

// GENIE MINIMIZE (Reddit, r/hyprland: "genie effect when minimizing/maximizing
// apps"). Off by default: plugin:hyprdrive:dock:minimize_genie.
//
// The window is drawn at its own place and size into an offscreen buffer --
// the flight's proxy for a minimize, the real window for a desktop restore --
// and a window transformer (CGenieTransformer) redraws that picture as thin
// horizontal strips: each strip narrows toward the icon's width and slides
// toward it, the lower strips leading, so the window pours into the dock like
// macOS's genie and pours back out on a restore. Without motion blur the
// transformed buffer covers the whole output, so the funnel may run anywhere;
// a flight already repaints the whole output every frame (Dock::pumpFrame).

#include <functional>

#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprland/src/helpers/math/Math.hpp>

namespace ScrollOverview::Genie {
    bool enabled();

    // A minimize (or overview restore) frame: draws the proxy via `drawAtWindow`
    // (at `windowBox`, full size) through the genie. Boxes are monitor-local
    // RENDER px; `g` is 0 at the window, 1 inside the icon.
    void drawProxy(PHLMONITOR monitor, const PHLWINDOW& window, const CBox& windowBox, const CBox& iconBox, float g, const std::function<void()>& drawAtWindow);

    // A driven restore frame: the real window stands at `windowBox` and draws
    // itself; the genie bends it out of the icon.
    void driveReal(PHLMONITOR monitor, const PHLWINDOW& window, const CBox& windowBox, const CBox& iconBox, float g);

    // After the frame's flights: windows no longer in a genie flight lose the
    // transformer (`stillFlying` says which are).
    void sweep(const std::function<bool(const PHLWINDOW&)>& stillFlying);

    // PLUGIN_EXIT / abort: every genie transformer comes off.
    void shutdown();
}
