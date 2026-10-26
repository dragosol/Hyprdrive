#pragma once

// THE INFINITE CANVAS (user, 2026-10-26: "an additional option in the mosaic
// mode, toggled off by default (when off, windows going past the screen size
// go into the current tiled mode)"). With mosaic:infinite_canvas on, a desktop
// whose windows no longer fit the screen does not tile: the windows keep their
// mosaic sizes and the desktop grows past the screen into a canvas the view
// pans across. Pure geometry, host-tested (scripts/mosaic_pack_test.cpp).
//
// The canvas is ONE mosaic cluster (user, 2026-10-26: "per my clustering
// rules on native windows shouldn't organize in rows ... there should be no
// spaces between windows as much as possible ... they can organize in rows but
// without spacing between them other than the hyprland padding"): the same
// packer as the plain mosaic (pack()), any order, every window at its own size
// with only the inner gap between neighbours -- in an area as many screens
// wide (horizontal) or wide and tall (all directions, landscape steps) as it
// takes to hold everyone. The canvas is that cluster's bounds.

#include "MosaicPack.hpp"

#include <algorithm>
#include <cmath>
#include <optional>
#include <vector>

namespace ScrollOverview::MosaicPack {

    struct SCanvasPack {
        std::vector<SRect> rects;  // per window, in the input order; canvas coordinates (0,0 = top left)
        double             w = 0, h = 0;
        size_t             screensX = 0, screensY = 0; // the area it took, in screens
    };

    // A window let go on the canvas lands where it was let go, the rest packed
    // around it (PackHint, as a drop in the plain mosaic): `x`/`y` in the
    // coordinates of the canvas it was dropped on, `oldW`/`oldH` that canvas's size.
    struct SCanvasDrop {
        size_t idx = 0;
        double x = 0, y = 0;
        double oldW = 0, oldH = 0;
    };

    // `area` is the screen's work area (the view), `loose` the eased one.
    inline SCanvasPack packCanvas(const std::vector<SRect>& sizes, const SRect& area, const std::optional<SRect>& loose, double gap, bool twoD,
                                  const SCanvasDrop* drop = nullptr) {
        SCanvasPack out;
        out.rects.resize(sizes.size());
        if (sizes.empty() || area.w < 1 || area.h < 1)
            return out;
        // A window bigger than the screen on its own is shown at most screen
        // sized (its mosaic size is untouched: Mosaic.cpp keeps `natural`).
        std::vector<SRect> s;
        for (const auto& R : sizes)
            s.push_back(SRect{0, 0, std::min(R.w, area.w), std::min(R.h, area.h)});

        // The smallest area that holds everyone: one screen, then a screen
        // more along x (horizontal), or alternately along x and y (all
        // directions: 1x1, 2x1, 2x2, 3x2, 3x3 ...).
        std::optional<std::vector<SRect>> placed;
        SRect                             big = area;
        size_t                            cx = 1, cy = 1;
        for (size_t step = 0; step <= 2 * sizes.size() + 2 && !placed; ++step) {
            big = SRect{area.x, area.y, area.w * static_cast<double>(cx) + gap * static_cast<double>(cx - 1),
                        area.h * static_cast<double>(cy) + gap * static_cast<double>(cy - 1)};
            std::optional<PackHint> hint;
            if (drop && drop->idx < s.size())
                hint = PackHint{.idx = drop->idx, .x = big.x + (big.w - drop->oldW) / 2.0 + drop->x, .y = big.y + (big.h - drop->oldH) / 2.0 + drop->y};
            const bool ONE = cx == 1 && cy == 1;
            if (ONE ? fitsEased(s, area, loose, gap) : fitLayout(s, big, gap, true).has_value())
                placed = ONE ? packEased(s, area, loose, gap, hint ? &*hint : nullptr) : pack(s, big, gap, hint ? &*hint : nullptr);
            if (placed)
                break;
            if (!twoD || cx <= cy)
                ++cx;
            else
                ++cy;
        }
        if (!placed) {
            // Nothing packs (cannot happen short of a broken size): a row.
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
        for (size_t i = 0; i < placed->size(); ++i) {
            const auto& R = (*placed)[i];
            out.rects[i]  = SRect{std::round(R.x - minX), std::round(R.y - minY), R.w, R.h};
        }
        out.w        = std::round(maxX - minX);
        out.h        = std::round(maxY - minY);
        out.screensX = cx;
        out.screensY = cy;
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

    // SMART FOCUS PAN (user, 2026-10-26: "windows can center on canvas when
    // focused ... the pan tries to (in order of priority, 1. fit the newly
    // focused window on screen, 2. if there is sufficient space, show the
    // adjacent window user focused from, 3. try and show at least edges of
    // other windows in proximity of the newly focused one)"). One axis of the
    // view's offset, canvas coordinates:
    //   1. `r` whole, `margin` around it, centred if nothing else asks;
    //   2. with `from` (the window focus came from) too, the two centred
    //      together if both fit; if not, the view leans toward it as far as
    //      `r` allows;
    //   3. at least `peek` px of the nearest neighbour on each side of `r`
    //      (from `near`: the windows beside it on this axis), where 1 and 2
    //      leave room.
    struct SSpan {
        double start = 0, len = 0;
        double end() const {
            return start + len;
        }
    };
    inline double smartRevealAxis(double viewLen, double maxOffset, const SSpan& r, const std::optional<SSpan>& from, const std::vector<SSpan>& near, double margin,
                                  double peek) {
        const auto CLAMP = [&](double o) { return std::clamp(o, 0.0, maxOffset); };
        if (r.len + 2 * margin >= viewLen)
            return CLAMP(r.start + r.len / 2.0 - viewLen / 2.0); // bigger than the view: centred
        double lo     = r.end() + margin - viewLen; // the offsets that show r whole
        double hi     = r.start - margin;
        double target = r.start + r.len / 2.0 - viewLen / 2.0;
        if (from) {
            const double US = std::min(r.start, from->start), UE = std::max(r.end(), from->end());
            if (UE - US + 2 * margin <= viewLen) {
                lo     = std::max(lo, UE + margin - viewLen);
                hi     = std::min(hi, US - margin);
                target = (US + UE) / 2.0 - viewLen / 2.0;
            } else if (from->end() <= r.start + 0.5 || from->start >= r.end() - 0.5)
                target = from->start < r.start ? hi : lo; // lean toward it
        }
        // 3. The nearest neighbour each side, a sliver of it.
        std::optional<double> leftEnd, rightStart;
        for (const auto& N : near) {
            if (N.end() <= r.start + 0.5 && (!leftEnd || N.end() > *leftEnd))
                leftEnd = N.end();
            if (N.start >= r.end() - 0.5 && (!rightStart || N.start < *rightStart))
                rightStart = N.start;
        }
        double plo = lo, phi = hi;
        if (leftEnd && *leftEnd - peek >= lo)
            phi = std::min(phi, *leftEnd - peek);
        if (rightStart && *rightStart + peek - viewLen <= hi)
            plo = std::max(plo, *rightStart + peek - viewLen);
        if (plo <= phi)
            target = std::clamp(target, plo, phi);
        return CLAMP(std::clamp(target, std::min(lo, hi), std::max(lo, hi)));
    }
}
