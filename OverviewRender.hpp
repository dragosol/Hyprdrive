#pragma once

#include "globals.hpp"

#include <hyprland/src/render/types.hpp>

#include <string>

namespace OverviewRender {

void flushPass(PHLMONITOR monitor);
void queueBlur(const CBox& box, int rounding, float roundingPower, float alpha, bool usePrecomputedBlur);
void renderBlur(PHLMONITOR monitor, const CBox& box, int rounding, float roundingPower, float alpha, bool usePrecomputedBlur);

// The texture for a desktop-entry Icon= value, decoded and uploaded once.
// AppSearch deliberately stops at the file path; the upload is render's job,
// and both the overview's result rows and the dock need the same cache.
SP<Render::ITexture> appIcon(const std::string& iconName);

}
