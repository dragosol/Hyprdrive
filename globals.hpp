#pragma once

#include <hyprland/src/plugins/PluginAPI.hpp>

inline HANDLE SCROLLOVERVIEW_HANDLE = nullptr;

bool ensureScrollOverviewHooks();
void disableScrollOverviewHooks();
