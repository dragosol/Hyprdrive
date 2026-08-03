#pragma once

#include "globals.hpp"

#include <string>
#include <vector>

// OVERVIEW_CPP_SPEC §13.9 X27. hyprgnomedock's SURFACE: a floating pill at the
// bottom of the monitor, proportioned from the reference Dash to Dock config.
// X25 (live previews) and X26 (drag-to-dock) both need something to draw into
// and drop onto, which is why the surface lands before them.
namespace ScrollOverview::Dock {

struct SItem {
    std::string wmClass;
    std::string icon;    // desktop-entry Icon=, "" when no entry claims the class
    CBox        iconBox; // monitor-local, RENDER px
};

// X25. One minimized window, drawn in the pill as the REAL window, live.
struct SPreview {
    PHLWINDOW window;
    CBox      box; // monitor-local, RENDER px
};

struct SLayout {
    CBox                  pill; // monitor-local, RENDER px; empty when there is nothing to draw
    int                   rounding = 0;
    std::vector<SItem>    items;
    std::vector<SPreview> previews;
};

// Pure geometry, so a test rig can assert proportions without a frame.
SLayout layout(PHLMONITOR monitor);
void    render(PHLMONITOR monitor);

// X26. Is a monitor-local RENDER px point inside the pill? The overview's drop
// handling asks this before it asks any workspace: the pill floats over the main
// area, so the card underneath would otherwise claim the drop.
bool    pillContains(PHLMONITOR monitor, const Vector2D& point);

// X24. A click inside the pill, in the same monitor-local RENDER px as
// pillContains. An icon toggles its app's minimized state
// (`click-action='minimize'`); a preview restores that one window. `shift`
// applies `minimize-shift` -- the whole app rather than just the front window.
// Returns whether an item claimed the click; the caller swallows the event
// either way, since the pill is not a window and must not leak clicks through.
bool    click(PHLMONITOR monitor, const Vector2D& point, bool shift);

// Damage the monitor when the pill's shape changes -- an app opening or closing,
// the dock being switched off, the hovered icon moving -- and every frame while a
// live preview is in it. MUST be called before the frame is rendered: damage
// asked for during the pass is cleared with the rest of the frame's ring.
//
// Returns whether the pill's appearance actually changed. The overview throttles
// scheduleFrame while it is open, so a plain damageMonitor from here is swallowed
// -- it has to answer with requestInputFrame() instead, and this is how it knows.
bool damageIfChanged(PHLMONITOR monitor);

}
