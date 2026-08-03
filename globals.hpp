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

// STANDING UX RULE (RICE_PROGRESS.md): the rice has exactly TWO motion curves,
// mirrored in hyprland/general.lua as `appleDecel`/`appleAccel` and in the
// quickshell Appearance.qml. Registered once with Hyprland's animation manager
// in CScrollOverview's constructor, so anything hand-rolled can evaluate the
// SAME curve object instead of approximating it with a polynomial.
inline constexpr const char* HOUSE_DECEL_BEZIER = "scrolloverviewOpen";
inline constexpr const char* HOUSE_ACCEL_BEZIER = "scrolloverviewClose";

// The house curve at t in [0,1]. Entrances decelerate, exits accelerate.
// Falls back to a cubic of the right direction if called before the curves are
// registered -- a wrong-but-sane shape beats linear.
float houseEase(bool decel, float t);

bool ensureScrollOverviewHooks();
void disableScrollOverviewHooks();
