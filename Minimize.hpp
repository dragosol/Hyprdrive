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

}
