#pragma once

// THE UI GLYPHS WITHOUT A NERD FONT (native port, docs/native/OMARCHY-AUDIT.md
// A15 / P1-6). The dock's context menu, the search pill's magnifier, the
// dictionary/translator header and the scratchpad's exit band name their icons
// as Font Awesome codepoints in the Private Use Area (U+F000..U+F2FF), drawn
// through "JetBrainsMono Nerd Font". Omarchy ships that font; plain Hyprland
// promises nothing, and a PUA codepoint no font covers is a TOFU BOX -- or,
// worse, a WRONG glyph: U+F001/U+F002 are the "fi"/"fl" ligatures in Apple's
// legacy PUA, and Ubuntu, Liberation and friends still map them (measured on
// fedora: `fc-list :charset=f002` lists Ubuntu and Liberation Serif), so a
// magnifier asked of the wrong font comes back as "fl".
//
// So every glyph the plugin names has an equivalent here, drawn by hand on a
// 16-unit grid as an SVG (original line art, not Font Awesome's outlines), and
// a plain-Unicode stand-in for the few that sit INSIDE a text label ("Change ›",
// "↑ Drag here to exit scratchpad", "Name ↕"). OverviewRender::glyph() and
// OverviewRender::text() choose between the font and these (Fonts.hpp decides
// whether a font covers a codepoint); nothing in here touches fontconfig, cairo
// or Hyprland, so scripts/glyphs_test.cpp checks it on the host.

#include <cstdint>
#include <functional>
#include <span>
#include <string>
#include <string_view>

namespace ScrollOverview::Glyphs {
    // The Private Use Areas: BMP (U+E000..U+F8FF) and planes 15-16 (Nerd Fonts'
    // Material Design icons live at U+F0000+).
    constexpr bool isPrivateUse(char32_t cp) {
        return (cp >= 0xE000 && cp <= 0xF8FF) || (cp >= 0xF0000 && cp <= 0x10FFFD);
    }

    // Cheap pre-check for a label: a PUA codepoint's UTF-8 starts with 0xEE,
    // 0xEF (BMP) or 0xF3/0xF4 (planes 15/16). False = certainly none, without
    // decoding; true = decode and look (0xEF also starts U+F900..U+FFFF).
    bool mayContainPrivateUse(std::string_view utf8);
    bool containsPrivateUse(std::string_view utf8);

    // Decode one codepoint at `at`, advancing it. Malformed bytes decode as
    // U+FFFD and advance one byte, so a loop over this always terminates.
    char32_t decode(std::string_view utf8, size_t& at);
    // The ONLY codepoint of a glyph string (""), ignoring a trailing
    // variation selector; 0 when the string is not exactly one glyph.
    char32_t single(std::string_view utf8);
    std::string encode(char32_t cp);

    // Every codepoint the plugin itself names -- what a candidate icon font
    // is scored against (Fonts.cpp) and what the host test walks.
    std::span<const char32_t> named();

    // hyprdrive's own drawing of `cp` as a complete SVG document in `hex`
    // ("#rrggbb") at `opacity` (0..1); empty when there is none.
    std::string svg(char32_t cp, std::string_view hex, float opacity = 1.F);
    bool        hasSvg(char32_t cp);

    // A plain-Unicode stand-in for `cp` inside running text ("›" for the
    // chevron, "↑" for the arrow), or empty: such a codepoint is DROPPED from
    // the label rather than drawn as a box.
    std::string_view standIn(char32_t cp);

    // `utf8` with every PUA codepoint that `fontCovers` rejects replaced by its
    // standIn (or removed), and the doubled spaces a removal leaves collapsed.
    // Covered codepoints are left for the font. Returns `utf8` unchanged when
    // nothing needed replacing.
    std::string substitute(std::string_view utf8, const std::function<bool(char32_t)>& fontCovers);
}
