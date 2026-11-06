#pragma once

// WHICH FILE OF AN ICON TO DRAW, when a theme has several: AppSearch's icon
// index scores every candidate it walks and keeps the best per name.
//
// Pure: no Hyprland. scripts/icon_score_test.cpp builds it on the host.

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <string>
#include <string_view>

namespace AppSearch::IconScore {

    // The size a theme directory is drawn for, from the directory NAMES
    // alone: "48x48" -> 48, "48x48@2x" -> 96, "48" -> 48, "scalable" ->
    // 4096 (it draws at any size); anything else (pixmaps, "symbolic", a
    // category folder) adds nothing. Only whole names count -- a digit
    // anywhere else on the path (a home called "w2s") is not a size.
    inline int iconDirSize(const std::filesystem::path& path) {
        const auto number = [](std::string_view s, size_t& i) {
            int n = 0;
            const size_t FROM = i;
            while (i < s.size() && std::isdigit(static_cast<unsigned char>(s[i])) && n < 100000)
                n = (n * 10) + (s[i++] - '0');
            return i == FROM ? -1 : n;
        };
        int size = 0;
        for (const auto& PART : path.parent_path()) {
            const std::string S = PART.string();
            if (S == "scalable") {
                size = std::max(size, 4096);
                continue;
            }
            size_t    i = 0;
            const int W = number(S, i);
            if (W < 0)
                continue;
            int scale = 1;
            if (i < S.size()) {
                if (S[i] != 'x' || number(S, ++i) < 0)
                    continue; // "x11", "2024-backup": not a size
                if (i < S.size()) {
                    if (S[i] != '@' || (scale = number(S, ++i)) < 1 || i + 1 != S.size() || S[i] != 'x')
                        continue;
                }
            }
            size = std::max(size, std::min(W, 4096) * std::min(scale, 4));
        }
        return std::min(size, 4096);
    }

    // Higher is better. SVG wins outright: one file scales to any row
    // height, so nothing has to be re-picked when the card transform
    // changes. Otherwise prefer the largest raster, parsed out of the
    // "256x256" style directory name.
    //
    // Among SVGs the LARGEST DESIGN wins too (G6). A theme like Papirus
    // ships one SVG per size, and they are different drawings, not one
    // drawing scaled: 16x16/mimetypes are thin line glyphs, 64x64 the
    // full-colour sheets. Every SVG used to score the same, so whichever
    // size directory the walk reached first won -- a stack's file icons
    // came out as tiny glyphs and a two-item pile an unreadable overlap.
    inline int iconCandidateScore(const std::filesystem::path& path) {
        if (path.extension() == ".svg")
            return 100000 + iconDirSize(path);

        if (path.extension() != ".png" && path.extension() != ".xpm")
            return -1;

        // A themeless location (pixmaps) still beats nothing.
        return iconDirSize(path);
    }

} // namespace AppSearch::IconScore
