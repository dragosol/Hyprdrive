#pragma once

#include "globals.hpp"

#include <hyprland/src/devices/IPointer.hpp>

// MOSAIC (user, 2026-10-11): a Hyprland tiled layout named "mosaic", after
// GNOME's planned Mosaic. Windows keep their natural size and gather into one
// cluster centred on the desktop; when they no longer fit -- too many, or one
// too big -- the same layout tiles them, and it returns to the mosaic by itself
// once they fit again. The desktop's layout stays "mosaic" throughout: the tile
// arrangement is its second half, not a switch to another layout.
//
// The geometry is MosaicPack.hpp (pure, host-tested). Super+L's three-way
// cycle, the settings section and "Mosaic as the default" live in the panel and
// its fragments; this side only provides the layout.
//
// Symcheck rule: the algorithm class is defined OUTSIDE any anonymous namespace
// in Mosaic.cpp -- Hyprland holds it by its vtable and its typeid.
namespace ScrollOverview::Mosaic {
    // PLUGIN_INIT: register "mosaic" with Hyprland's layout matcher.
    void registerLayout(HANDLE handle);
    // PLUGIN_EXIT, FIRST: every desktop on mosaic is handed back to the default
    // layout -- its algorithm objects destroyed -- while this code is mapped.
    void unregisterLayout(HANDLE handle);

    // CORNER RESIZE (Mosaic.cpp). A mouse button event, before Hyprland sees
    // it: true = claimed (a corner resize started, or ours ended). `blocked`:
    // the overview, the dock or a lock screen owns the pointer.
    bool onButton(const IPointer::SButtonEvent& e, bool blocked);
    // A key while the canvas is zoomed out (Super held): true = taken.
    bool onZoomKey(uint32_t keycode, bool pressed);
    // Pointer motion: the resize cursor while over a grabbable corner.
    void onMove(bool blocked);
    // Super zoomed the canvas out: pointer motion is the zoom's alone, never
    // Hyprland's focus follows mouse over the windows' real (full size) places.
    bool zoomOwnsPointer();
    // Raw pointer motion: `delta` asked, `moved` what the pointer really moved
    // (less at a screen's edge). A resize reaches past the edge by the rest.
    void onPointerDelta(const Vector2D& delta, const Vector2D& moved);
    // A window is closing (Hyprland's window.close, before the layout drops
    // it): on a desktop in the mosaic arrangement, its size becomes its app's
    // size in mosaic from now on.
    void onWindowClose(const PHLWINDOW& w);
    // PLUGIN_EXIT: our drag ended, our cursor override dropped.
    void shutdown();

    // THE INFINITE CANVAS (MosaicCanvas.hpp, mosaic:infinite_canvas). A mosaic
    // desktop on its canvas pans like the scrolling layout's tape: the desktop
    // swipe (OverviewGesture) and Super+scroll (DesktopSwitch) move the view
    // first and switch desktops only past either end of it.
    struct SCanvasProbe {
        bool   usable    = false; // on the canvas, and wider than the view
        double offset    = 0.0;   // the view's left edge along the canvas
        double maxOffset = 0.0;
    };
    SCanvasProbe canvasProbe(const PHLWORKSPACE& ws);
    // Put the view at `offsetX` (clamped). `warp`: no animation (a swipe tracks the fingers).
    void canvasSetOffset(const PHLWORKSPACE& ws, double offsetX, bool warp);
    // A swipe started / is over: focus does not pull the view while it pans;
    // at the end, focus goes to a window in view if the focused one left it.
    void canvasPanning(bool on);
    void canvasSettle(const PHLWORKSPACE& ws);
    // Super+scroll: half a screen along the canvas; false at that end.
    bool canvasStep(const PHLWORKSPACE& ws, int dir);
    // Super went down / came up (main.cpp's key hook): the canvas's Super
    // gesture -- hold and move to pan or zoom out (mosaic:canvas_super_move),
    // never while a Super+click or Super+drag has used the press.
    void onSuperKey(bool pressed);
    // Is `w` on a canvas whose view is moving (a pan, the zoom, a swipe, a
    // drag pushing at the edge)? The layout motion blur leaves it alone.
    bool canvasMotion(const PHLWINDOW& w);
    // The whole canvas in global layout coordinates at the current view, for
    // the overview's strip thumbnail (the whole canvas, zoomed out). Nothing
    // when the desktop is not on its canvas.
    std::optional<CBox> canvasBox(const PHLWORKSPACE& ws);
}
