#pragma once

#include <hyprland/src/plugins/PluginAPI.hpp>

#include <string>

inline HANDLE SCROLLOVERVIEW_HANDLE = nullptr;

// OVERVIEW_CPP_SPEC §5 F2 type-to-filter query. Written by the keyboard hook in
// main.cpp, read by the window gate in scrollOverview.cpp.
inline std::string g_overviewSearch;

// OVERVIEW_CPP_SPEC §13.2 F3. Index into the ranked app results, -1 meaning
// "no app selected, the grid owns Return". Paired with the query above: any
// edit to the query resets it.
inline int g_overviewAppSelection = -1;

bool ensureScrollOverviewHooks();
void disableScrollOverviewHooks();
