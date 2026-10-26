#pragma once

// THE INFINITE CANVAS (user, 2026-10-26: "an additional option in the mosaic
// mode, toggled off by default (when off, windows going past the screen size
// go into the current tiled mode)"). With mosaic:infinite_canvas on, a desktop
// whose windows no longer fit the screen does not tile: the windows keep their
// mosaic sizes and the desktop grows past the screen into a canvas the view
// pans across. Pure geometry, host-tested (scripts/mosaic_pack_test.cpp).
//
// The canvas is made of GROUPS: each group is an ordinary mosaic cluster that
// fits the screen (pack()/packEased(), the same packer as the plain mosaic),
// filled greedily in the layout's order. Horizontal: the groups stand in one
// row, so the canvas is a strip (panning past either end switches desktops,
// as the scrolling layout's tape does). All directions (user, 2026-10-26):
// the groups fill a near-square grid, row by row.

#include "MosaicPack.hpp"

#include <algorithm>
#include <cmath>
#include <vector>

namespace ScrollOverview::MosaicPack {

    struct SCanvasPack {
        std::vector<SRect> rects; // per window, in the input order; canvas coordinates (0,0 = top left)
        double             w = 0, h = 0;
        size_t             groups = 0;
    };

    // `area` is the screen's work area (the view), `loose` the eased one.
    inline SCanvasPack packCanvas(const std::vector<SRect>& sizes, const SRect& area, const std::optional<SRect>& loose, double gap, bool twoD) {
        SCanvasPack out;
        out.rects.resize(sizes.size());
        if (sizes.empty() || area.w < 1 || area.h < 1)
            return out;

        struct SGroup {
            std::vector<size_t> idx;
            std::vector<SRect>  local; // relative to the group's own top left
            double              w = 0, h = 0;
        };
        std::vector<SGroup> groups;

        // A window bigger than the screen on its own is shown at most screen
        // sized (its mosaic size is untouched: Mosaic.cpp keeps `natural`).
        const auto CLAMPED = [&](const SRect& r) { return SRect{0, 0, std::min(r.w, area.w), std::min(r.h, area.h)}; };

        const auto CLOSE = [&](std::vector<size_t>& idx) {
            if (idx.empty())
                return;
            SGroup g;
            g.idx = idx;
            std::vector<SRect> s;
            for (const auto I : idx)
                s.push_back(CLAMPED(sizes[I]));
            auto placed = packEased(s, area, loose, gap);
            if (!placed) {
                // One window that will not pack even alone (screen sized after
                // the clamp, within rounding): it fills the view.
                placed = std::vector<SRect>{};
                double x = area.x;
                for (const auto& R : s) {
                    placed->push_back({x, area.y, R.w, R.h});
                    x += R.w + gap;
                }
            }
            double minX = 1e18, minY = 1e18, maxX = -1e18, maxY = -1e18;
            for (const auto& R : *placed) {
                minX = std::min(minX, R.x);
                minY = std::min(minY, R.y);
                maxX = std::max(maxX, R.x + R.w);
                maxY = std::max(maxY, R.y + R.h);
            }
            for (const auto& R : *placed)
                g.local.push_back({R.x - minX, R.y - minY, R.w, R.h});
            g.w = maxX - minX;
            g.h = maxY - minY;
            groups.push_back(std::move(g));
            idx.clear();
        };

        // Greedy, in order: a window joins the group while the group still
        // packs at the screen's size, and opens the next one when it would not.
        std::vector<size_t> current;
        for (size_t i = 0; i < sizes.size(); ++i) {
            current.push_back(i);
            std::vector<SRect> s;
            for (const auto I : current)
                s.push_back(CLAMPED(sizes[I]));
            if (current.size() > 1 && !fitsEased(s, area, loose, gap)) {
                current.pop_back();
                CLOSE(current);
                current.push_back(i);
            }
        }
        CLOSE(current);
        out.groups = groups.size();

        // The groups into rows: one row (horizontal), or a near-square grid.
        const size_t COLS = twoD ? std::max<size_t>(1, static_cast<size_t>(std::ceil(std::sqrt(sc_double(groups.size()))))) : groups.size();
        struct SRow {
            size_t first = 0, count = 0;
            double w = 0, h = 0;
        };
        std::vector<SRow> rows;
        for (size_t g = 0; g < groups.size(); g += COLS) {
            SRow r{.first = g, .count = std::min(COLS, groups.size() - g)};
            for (size_t k = 0; k < r.count; ++k) {
                r.w += groups[g + k].w + (k ? gap : 0.0);
                r.h = std::max(r.h, groups[g + k].h);
            }
            rows.push_back(r);
        }
        for (const auto& R : rows) {
            out.w = std::max(out.w, R.w);
            out.h += R.h;
        }
        out.h += gap * sc_double(rows.empty() ? 0 : rows.size() - 1);

        // Each row centred across the canvas, each group centred down its row.
        double y = 0;
        for (const auto& R : rows) {
            double x = (out.w - R.w) / 2.0;
            for (size_t k = 0; k < R.count; ++k) {
                const auto&  G  = groups[R.first + k];
                const double GY = y + (R.h - G.h) / 2.0;
                for (size_t j = 0; j < G.idx.size(); ++j) {
                    const auto& L          = G.local[j];
                    out.rects[G.idx[j]] = SRect{std::round(x + L.x), std::round(GY + L.y), L.w, L.h};
                }
                x += G.w + gap;
            }
            y += R.h + gap;
        }
        out.w = std::round(out.w);
        out.h = std::round(out.h);
        return out;
    }

    // Where the canvas sits on screen for a view offset, and the offsets the
    // view may take. A canvas narrower (shorter) than the view is centred on
    // that axis and does not pan along it.
    struct SCanvasView {
        double originX = 0, originY = 0;   // screen position of canvas (0,0) at offset 0
        double maxX = 0, maxY = 0;         // offsets run 0..max
    };
    inline SCanvasView canvasView(double canvasW, double canvasH, const SRect& area) {
        SCanvasView v;
        v.maxX    = std::max(0.0, canvasW - area.w);
        v.maxY    = std::max(0.0, canvasH - area.h);
        v.originX = canvasW <= area.w ? area.x + (area.w - canvasW) / 2.0 : area.x;
        v.originY = canvasH <= area.h ? area.y + (area.h - canvasH) / 2.0 : area.y;
        return v;
    }

    // The smallest move of the view (offset, clamped to 0..max) that shows
    // `r` (canvas coordinates) whole, with `margin` around it where possible.
    inline double revealAxis(double offset, double rStart, double rLen, double viewLen, double maxOffset, double margin) {
        const double LO = rStart - margin, HI = rStart + rLen + margin;
        if (HI - LO >= viewLen)
            offset = rStart + rLen / 2.0 - viewLen / 2.0; // bigger than the view: centre it
        else if (LO < offset)
            offset = LO;
        else if (HI > offset + viewLen)
            offset = HI - viewLen;
        return std::clamp(offset, 0.0, maxOffset);
    }
}
