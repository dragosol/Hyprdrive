#pragma once

#include <hyprland/src/plugins/PluginAPI.hpp>

#include <string>

inline HANDLE SCROLLOVERVIEW_HANDLE = nullptr;

// OVERVIEW_CPP_SPEC §5 F2 type-to-filter query. Written by the keyboard hook in
// main.cpp, read by the window gate in scrollOverview.cpp.
inline std::string g_overviewSearch;

bool ensureScrollOverviewHooks();
void disableScrollOverviewHooks();
