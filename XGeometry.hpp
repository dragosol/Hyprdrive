#pragma once

#include <string>

// A FULLSCREEN GAME WHOSE X SIDE DISAGREES WITH HYPRLAND (user, 2026-10-21:
// "the mouse coords don't match the cursor" in Overwatch under Proton;
// Alt+Enter out of fullscreen and back fixes it, minimize and restore
// sometimes does not).
//
// Two ways it happens, both checked on pointer motion for the focused
// fullscreen X11 window:
//
// 1. The window's box. X was left with the tiled box (3828x2148 at 6,6) while
//    Hyprland drew the window fullscreen at 0,0 3840x2160. sendWindowSize skips
//    a send whose box matches what Hyprland believes the client has, and that
//    belief was not what X had. Fixed by forcing one send when the box X
//    reports (ConfigureNotify keeps CXWaylandSurface::m_geometry) differs.
//
// 2. Wine's cursor clip. A fullscreen Wine game confines the pointer with an
//    X grab on an InputOnly, override-redirect window sized to the rect the
//    game clipped to. The game clips when it is activated, and when Hyprland
//    activates it while it is briefly tiled (a window picked under it, then
//    the game again) or before its emulated display mode settles, that rect is
//    the tile box or a 1920x1080 quarter. The game then goes fullscreen and
//    never clips again: X's pointer stays pinned to the old rect's edge while
//    Hyprland's cursor moves on, so the game acts somewhere else than the
//    cursor is. Alt+Enter cured it because the game clips again on a mode
//    change. The signature is unambiguous -- X's pointer inside a mapped
//    InputOnly override-redirect window that Hyprland's cursor has left -- and
//    the fix is the clip the game would have asked for: that window is moved
//    to the fullscreen window's box.
//
// Neither runs while a ConfigureHold is up or the window is animating: those
// boxes are in-between on purpose.

namespace ScrollOverview::XGeometry {
    // main.cpp, after each pointer motion.
    void check();

    // PLUGIN_EXIT: drop the X connection the clip check opened.
    void shutdown();

    // `hyprdrive:debug xgeom`: what check() would see right now, without
    // acting -- which condition lets it through or stops it.
    std::string status();
}
