#pragma once

#include "globals.hpp"

#include <hyprland/src/render/types.hpp>

#include <string>

namespace OverviewRender {

void flushPass(PHLMONITOR monitor);
void queueBlur(const CBox& box, int rounding, float roundingPower, float alpha, bool usePrecomputedBlur);

// The texture for a desktop-entry Icon= value, decoded and uploaded once.
// AppSearch deliberately stops at the file path; the upload is render's job,
// and both the overview's result rows and the dock need the same cache.
SP<Render::ITexture> appIcon(const std::string& iconName);

// OVERVIEW_CPP_SPEC 13.12 X57. The label plate, drawn ONCE for both surfaces
// that need one: hyprgnomedock's icon tooltip and the overview tile's caption.
// GNOME styles its `.dash-label` and its `.window-caption` with a single css
// rule, so a single function here is the same decision -- and it is what stops
// the two drifting apart the next time one of them is tuned.
//
// Centred horizontally on `cx`, with the plate's BOTTOM edge at `bottomY`.
// Returns the plate box, or an empty box if the text could not be rendered.
CBox labelPill(PHLMONITOR monitor, const std::string& str, double cx, double bottomY, float alpha, float scale);

// g_pHyprRenderer->renderText(), cached on everything that changes the pixels.
//
// The uncached call rasterises through pango/cairo and then UPLOADS a texture,
// and every caller in this plugin is in a render path -- the dock's tooltip is
// rebuilt on every frame the pointer rests on an icon, and a menu row on every
// frame the menu is open. On this VM's virgl the upload is also a copy across
// to the host, which makes it the most expensive thing a frame can repeat.
//
// Same signature and argument order as the renderer's own call, so a site
// becomes cached by gaining a prefix and nothing else.
SP<Render::ITexture> text(const std::string& str, const CHyprColor& color, int fontSize, bool italic = false, const std::string& fontFamily = "", int maxWidth = 0,
                          int weight = 0);

// Drop the text cache. Called when an overview goes away: the strings it held
// were window titles and search results that the next one will not ask for.
void                 clearTextCache();

}
