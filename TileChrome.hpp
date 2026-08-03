#pragma once

#include "globals.hpp"

// OVERVIEW_CPP_SPEC 13.5 X7 (hover blow-up, press shrink) and X8 (app icon on
// the tile), plus the user's 2026-08-02 amendment: a close button on the
// TOP RIGHT of the hovered tile.
//
// State lives here rather than on CScrollOverview because there is exactly one
// cursor: hover is a property of the session, not of a monitor's overview.
namespace ScrollOverview::TileChrome {

// The cursor moved. Pass nullptr when it is over no tile.
void setHovered(const PHLWINDOW& window);

// The primary button went down on / came up from the hovered tile. Drives X7's
// "shrink just a little bit as pressed feedback".
void setPressed(const PHLWINDOW& window, bool down);

// The overview closed. Drops every ease so the next open starts cold instead of
// replaying the state the user left behind.
void forget();

// The tile the cursor is on, or null. The caller needs it to keep the hover
// alive while the cursor sits on the close button, which pokes a few px past
// the unscaled hit area the hover test uses.
PHLWINDOW hovered();

bool isHovered(const PHLWINDOW& window);

// An ease is still running, so the caller owes another frame.
bool animating();

// The grid slot, grown by the hover ease and shrunk by the press ease, about its
// own centre. Render AND the close-button hit-test both go through this: a
// button placed off the unscaled box lands somewhere the tile is not.
CBox scaledBox(const PHLWINDOW& window, const CBox& base);

// The close button's circle, or an empty box when this tile has no button.
// Deliberately inset rather than straddling the corner: a button hanging off the
// tile would leave the tile's hit area, un-hover it, and delete itself under the
// cursor.
CBox closeButtonBox(const PHLWINDOW& window, const CBox& tileBox, float monitorScale);

// App icon (X8) + close button, drawn over an already-rendered tile.
void render(PHLMONITOR monitor, const PHLWINDOW& window, const CBox& tileBox, float monitorScale);

}
