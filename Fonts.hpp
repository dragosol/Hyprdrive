#pragma once

// FONTCONFIG, ASKED PROPERLY (native port, docs/native/OMARCHY-AUDIT.md A14 /
// A15). Two questions the plugin used to answer by guessing:
//
//   * "Which family is the user's monospace?" -- answered on Omarchy by the
//     first <string> in ~/.config/fontconfig/fonts.conf (where `omarchy font
//     set` writes it; Config.cpp keeps that path for Omarchy). A regex over
//     fonts.conf picks up aliases and reject entries just as happily, so off
//     Omarchy it is FcFontMatch on the pattern, with the config's own
//     substitutions applied -- the family pango would end up drawing anyway.
//
//   * "Is there a font for the UI glyphs?" (Glyphs.hpp) -- the code named
//     "JetBrainsMono Nerd Font" and hoped. Now every installed family that
//     covers the folder glyph (U+F07C, which no ligature table uses) is scored
//     on how many of Glyphs::named() it covers; one that covers at least
//     MIN_COVERAGE of them is THE icon font, and any codepoint it lacks falls
//     to Glyphs' own SVG. "JetBrainsMono Nerd Font" wins whenever it
//     qualifies, so an Omarchy install renders exactly what it always did.
//
// fontconfig only -- no Hyprland, pango or cairo -- so scripts/fonts_test.cpp
// runs it on the host against a FONTCONFIG_FILE it writes. Everything here is
// called from the render thread (OverviewRender, Config.cpp), and caches: a
// detection walks every installed font's charset (a few ms on a desktop with
// ~1000 faces), so it runs once per setting, at first use, not per frame.

#include <string>
#include <string_view>

namespace ScrollOverview::Fonts {
    // The family fontconfig resolves `pattern` ("monospace", "sans-serif",
    // "Iosevka") to. Empty if fontconfig cannot initialise or matches nothing.
    std::string matchFamily(const std::string& pattern);

    // True when a face whose family (any of its names) is exactly `family` is
    // installed -- not merely substitutable, which FcFontMatch always is.
    bool installed(const std::string& family);

    // The family the plugin's own Font Awesome glyphs are drawn in.
    //   setting "auto" (or empty)  detect, as above
    //   setting "builtin"          no font: every glyph is Glyphs' SVG
    //   anything else              that family, if installed; else detect
    // Empty = no usable icon font. Cached per setting.
    const std::string& iconFamily(std::string_view setting);

    // Does the font iconFamily(setting) chose have a glyph for `cp`? False when
    // there is no icon font. A codepoint outside Glyphs::named() (an Omarchy
    // menu icon, say) is answered from that font's charset all the same.
    bool iconCovers(std::string_view setting, char32_t cp);

    // How many of Glyphs::named() the chosen font covers (diagnostics: the
    // `debug glyphs` line and the host test).
    size_t iconCoverage(std::string_view setting);

    // Accept a candidate covering at least this share of Glyphs::named().
    inline constexpr double MIN_COVERAGE = 0.8;

    // Forget everything (tests; a font installed mid-session needs Hyprland's
    // own pango to see it too, which this cannot arrange).
    void reset();
}
