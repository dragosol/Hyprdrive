#pragma once

#include "globals.hpp"

#include <vector>

// OVERVIEW_CPP_SPEC §13.9 X24. The compositor half of hyprgnomedock's
// minimize: the dock surface does not exist yet, and this is what its icon
// clicks will drive once it does.
namespace ScrollOverview::Minimize {

bool                   isMinimized(PHLWINDOW window);
bool                   minimize(PHLWINDOW window);
bool                   restore(PHLWINDOW window);
std::vector<PHLWINDOW> minimized();

// Y9/Y10. The desktop a stashed window came FROM. A minimized window's own
// m_workspace is the stash, so nothing else can answer this -- the overview
// needs it to place the window's tile, and the flight needs it to know which
// way an off-screen desktop lies. WORKSPACE_INVALID when not minimized.
WORKSPACEID            originalWorkspace(PHLWINDOW window);

}
