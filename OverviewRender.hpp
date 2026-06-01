#pragma once

#include "globals.hpp"

namespace OverviewRender {

void flushPass(PHLMONITOR monitor);
void queueBlur(const CBox& box, int rounding, float roundingPower, float alpha, bool usePrecomputedBlur);
void renderBlur(PHLMONITOR monitor, const CBox& box, int rounding, float roundingPower, float alpha, bool usePrecomputedBlur);

}
