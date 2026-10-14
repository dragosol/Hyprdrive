// See Glyphs.hpp. No Hyprland, cairo or fontconfig headers: scripts/glyphs_test.cpp
// links this file on the host.
#include "Glyphs.hpp"

#include <algorithm>
#include <array>
#include <cstdio>

namespace {
    // One row per codepoint the plugin names. `stroke` is line art on a 16x16
    // grid (stroke 1.5, round caps and joins -- it reads as the same family as
    // the Adwaita symbolics the dock's app icons sit beside); `fill` is solid
    // shapes in the same colour. `standIn` is for running text only, and is
    // kept to WGL4 characters -- the set every Latin UI font (DejaVu, Noto Sans,
    // Liberation, Ubuntu, Cantarell) carries -- so the stand-in cannot itself
    // be a box. Sorted by codepoint: find() is a binary search.
    struct SGlyph {
        char32_t         cp;
        const char*      name; // Font Awesome's name for it, for the reader
        const char*      stroke;
        const char*      fill;
        std::string_view standIn;
    };

    constexpr std::array GLYPHS{
        SGlyph{0xF002, "search", "M10.2 10.2L14 14", "", ""},
        SGlyph{0xF005, "star", "", "M8 1.6l1.95 4.1 4.45.55-3.27 3.08.85 4.42L8 11.6l-3.98 2.15.85-4.42L1.6 6.25l4.45-.55z", ""},
        SGlyph{0xF006, "star-o", "M8 2.2l1.75 3.65 3.95.5-2.9 2.75.75 3.95L8 11.15l-3.55 1.9.75-3.95L2.3 6.35l3.95-.5z", "", ""},
        SGlyph{0xF00A, "th", "", "M2 2h3.4v3.4H2zM6.3 2h3.4v3.4H6.3zM10.6 2H14v3.4h-3.4zM2 6.3h3.4v3.4H2zM6.3 6.3h3.4v3.4H6.3zM10.6 6.3H14v3.4h-3.4zM2 10.6h3.4V14H2zM6.3 10.6h3.4V14H6.3zM10.6 10.6H14V14h-3.4z", ""},
        SGlyph{0xF00C, "check", "M3 8.6l3.1 3.1L13 4.6", "", ""},
        SGlyph{0xF00D, "times", "M4 4l8 8M12 4l-8 8", "", "×"},
        SGlyph{0xF017, "clock", "M8 4.6V8l2.6 1.6", "", ""},
        SGlyph{0xF02B, "tag", "M2.5 2.5h5.3l5.9 5.9-5.3 5.3-5.9-5.9z", "M6.4 5.2a1.2 1.2 0 1 1-2.4 0 1.2 1.2 0 0 1 2.4 0z", ""},
        SGlyph{0xF02D, "book", "M3.2 12.3V3.6c0-.7.5-1.1 1.1-1.1h8.3v9.2H4.4c-.7 0-1.2.5-1.2 1.2s.5 1.2 1.2 1.2h8.2", "", ""},
        SGlyph{0xF036, "align-left", "M2.5 3.5h11M2.5 6.5h7M2.5 9.5h11M2.5 12.5h7", "", ""},
        SGlyph{0xF03E, "image", "M3.4 2.8h9.2c.6 0 1 .4 1 1v8.4c0 .6-.4 1-1 1H3.4c-.6 0-1-.4-1-1V3.8c0-.6.4-1 1-1zM2.6 11.6l3.4-3.4 2.6 2.6 1.8-1.8 3 3", "M7 6a1.2 1.2 0 1 1-2.4 0A1.2 1.2 0 0 1 7 6z", ""},
        SGlyph{0xF040, "pencil", "M10.6 2.6l2.8 2.8-7.8 7.8H2.8v-2.8zM9 4.2l2.8 2.8", "", ""},
        SGlyph{0xF047, "arrows", "M8 2v12M2 8h12M6.2 3.8L8 2l1.8 1.8M6.2 12.2L8 14l1.8-1.8M3.8 6.2L2 8l1.8 1.8M12.2 6.2L14 8l-1.8 1.8", "", ""},
        SGlyph{0xF052, "eject", "", "M8 2.6l5.2 6H2.8zM2.8 10.6h10.4v2.4H2.8z", ""},
        SGlyph{0xF053, "chevron-left", "M10.2 2.8L5 8l5.2 5.2", "", "‹"},
        SGlyph{0xF054, "chevron-right", "M5.8 2.8L11 8l-5.2 5.2", "", "›"},
        SGlyph{0xF05A, "info-circle", "M8 7.2v4.2", "M8.95 4.9a.95.95 0 1 1-1.9 0 .95.95 0 0 1 1.9 0z", ""},
        SGlyph{0xF05E, "ban", "M3.9 3.9l8.2 8.2", "", ""},
        SGlyph{0xF062, "arrow-up", "M8 13.6V2.8M3.6 7.2L8 2.8l4.4 4.4", "", "↑"},
        SGlyph{0xF067, "plus", "M8 2.8v10.4M2.8 8h10.4", "", "+"},
        SGlyph{0xF07C, "folder-open", "M2.2 12.6V3.6c0-.4.3-.8.8-.8h3.1l1.5 1.5h4.6c.4 0 .8.3.8.8v1.6M2.2 12.6l2-5.4h10.4l-2 5.4z", "", ""},
        SGlyph{0xF08D, "thumb-tack", "M5.5 2.2h5M6.6 2.2v4.2L4.4 9.2h7.2L9.4 6.4V2.2M8 9.2v4.8", "", ""},
        SGlyph{0xF0A0, "hdd", "M2.2 8.6L4.4 3h7.2l2.2 5.6M3.2 8.6h9.6c.6 0 1 .4 1 1v2.6c0 .6-.4 1-1 1H3.2c-.6 0-1-.4-1-1V9.6c0-.6.4-1 1-1z", "M11.9 10.9a.9.9 0 1 1-1.8 0 .9.9 0 0 1 1.8 0z", ""},
        SGlyph{0xF0C1, "link", "M7 9.4l-1.2 1.2a2.4 2.4 0 0 1-3.4-3.4l2-2a2.4 2.4 0 0 1 3.4 0M9 6.6l1.2-1.2a2.4 2.4 0 0 1 3.4 3.4l-2 2a2.4 2.4 0 0 1-3.4 0", "", ""},
        SGlyph{0xF0C5, "copy", "M6 5.2h6.6c.5 0 .9.4.9.9v7c0 .5-.4.9-.9.9H6c-.5 0-.9-.4-.9-.9v-7c0-.5.4-.9.9-.9zM2.6 10.8V2.9c0-.3.2-.5.5-.5h7", "", ""},
        SGlyph{0xF0DC, "sort", "", "M8 1.8l4 4.6H4zM8 14.2l4-4.6H4z", "↕"},
        SGlyph{0xF0E8, "sitemap", "M8 5.4v2.6M3.6 10.6V8h8.8v2.6M6.4 1.8h3.2c.3 0 .5.2.5.5v2.6c0 .3-.2.5-.5.5H6.4c-.3 0-.5-.2-.5-.5V2.3c0-.3.2-.5.5-.5zM2 10.6h3.2c.3 0 .5.2.5.5v2.6c0 .3-.2.5-.5.5H2c-.3 0-.5-.2-.5-.5v-2.6c0-.3.2-.5.5-.5zM10.8 10.6H14c.3 0 .5.2.5.5v2.6c0 .3-.2.5-.5.5h-3.2c-.3 0-.5-.2-.5-.5v-2.6c0-.3.2-.5.5-.5z", "", ""},
        SGlyph{0xF120, "terminal", "M2.8 4l4 4-4 4M8.4 12.4h4.8", "", ""},
        SGlyph{0xF15B, "file", "M4 1.8h5.2l3.4 3.4v8.4c0 .3-.3.6-.6.6H4c-.3 0-.6-.3-.6-.6V2.4c0-.3.3-.6.6-.6zM9 1.8v3.6h3.6", "", ""},
        SGlyph{0xF187, "archive", "M2.4 2.8h11.2v3H2.4zM3.4 5.8v6.8c0 .4.3.6.6.6h8c.4 0 .6-.3.6-.6V5.8M6.4 8.4h3.2", "", ""},
        SGlyph{0xF1AB, "language", "M2 8h12M8 2c1.7 1.6 2.6 3.7 2.6 6S9.7 12.4 8 14M8 2C6.3 3.6 5.4 5.7 5.4 8s.9 4.4 2.6 6", "", ""},
        SGlyph{0xF1B2, "cube", "M8 1.9l5.6 3.1v6L8 14.1 2.4 11V5zM2.4 5L8 8.1 13.6 5M8 8.1v6", "", ""},
        SGlyph{0xF1C0, "database", "M2.8 4v8c0 1.1 2.3 2 5.2 2s5.2-.9 5.2-2V4M2.8 8c0 1.1 2.3 2 5.2 2s5.2-.9 5.2-2M13.2 4c0 1.1-2.3 2-5.2 2S2.8 5.1 2.8 4 5.1 2 8 2s5.2.9 5.2 2z", "", ""},
        SGlyph{0xF1F8, "trash", "M2.4 4.2h11.2M6 4.2V2.6h4v1.6M3.8 4.2l.7 9.2h7l.7-9.2M6.6 6.8v4.2M9.4 6.8v4.2", "", ""},
        SGlyph{0xF2D0, "window-maximize", "M3.2 2.8h9.6c.6 0 1 .4 1 1v8.4c0 .6-.4 1-1 1H3.2c-.6 0-1-.4-1-1V3.8c0-.6.4-1 1-1z", "M2.2 3.8c0-.6.4-1 1-1h9.6c.6 0 1 .4 1 1v2.2H2.2z", ""},
        SGlyph{0xF2D1, "window-minimize", "M3.6 10.6h8.8", "", ""},
        SGlyph{0xF2D2, "window-restore", "M5.6 5V3.2c0-.4.3-.7.7-.7h6.9c.4 0 .7.3.7.7v6.4c0 .4-.3.7-.7.7h-1.6M2.8 5.6h7.4c.4 0 .7.3.7.7v6.8c0 .4-.3.7-.7.7H2.8c-.4 0-.7-.3-.7-.7V6.3c0-.4.3-.7.7-.7z", "", ""},
    };

    // The circles some glyphs are built on, kept out of the path strings above
    // so the shapes stay legible: cx, cy, r (stroke only).
    struct SCircle {
        char32_t cp;
        float    cx, cy, r;
    };
    constexpr std::array CIRCLES{
        SCircle{0xF002, 6.6F, 6.6F, 4.6F}, // search: the lens
        SCircle{0xF017, 8.F, 8.F, 6.F},    // clock: the face
        SCircle{0xF05A, 8.F, 8.F, 6.F},    // info-circle
        SCircle{0xF05E, 8.F, 8.F, 5.8F},   // ban
        SCircle{0xF1AB, 8.F, 8.F, 6.F},    // language: a globe
    };

    constexpr bool sortedTable() {
        for (size_t i = 1; i < GLYPHS.size(); ++i)
            if (GLYPHS[i - 1].cp >= GLYPHS[i].cp)
                return false;
        return true;
    }
    static_assert(sortedTable(), "Glyphs: GLYPHS must stay sorted by codepoint (find() is a binary search)");

    constexpr std::array<char32_t, GLYPHS.size()> namedCodepoints() {
        std::array<char32_t, GLYPHS.size()> out{};
        for (size_t i = 0; i < GLYPHS.size(); ++i)
            out[i] = GLYPHS[i].cp;
        return out;
    }
    constexpr auto NAMED = namedCodepoints();

    const SGlyph* find(char32_t cp) {
        const auto IT = std::ranges::lower_bound(GLYPHS, cp, {}, &SGlyph::cp);
        return IT != GLYPHS.end() && IT->cp == cp ? &*IT : nullptr;
    }
}

namespace ScrollOverview::Glyphs {
    bool mayContainPrivateUse(std::string_view utf8) {
        return std::ranges::any_of(utf8, [](char c) {
            const auto B = static_cast<unsigned char>(c);
            return B == 0xEE || B == 0xEF || B == 0xF3 || B == 0xF4;
        });
    }

    char32_t decode(std::string_view s, size_t& at) {
        const auto B0 = static_cast<unsigned char>(s[at]);
        const auto CONT = [&](size_t i) { return at + i < s.size() && (static_cast<unsigned char>(s[at + i]) & 0xC0) == 0x80; };
        const auto BYTE = [&](size_t i) { return static_cast<char32_t>(static_cast<unsigned char>(s[at + i]) & 0x3F); };
        if (B0 < 0x80) {
            at += 1;
            return B0;
        }
        if ((B0 & 0xE0) == 0xC0 && CONT(1)) {
            const char32_t CP = (static_cast<char32_t>(B0 & 0x1F) << 6) | BYTE(1);
            at += 2;
            return CP;
        }
        if ((B0 & 0xF0) == 0xE0 && CONT(1) && CONT(2)) {
            const char32_t CP = (static_cast<char32_t>(B0 & 0x0F) << 12) | (BYTE(1) << 6) | BYTE(2);
            at += 3;
            return CP;
        }
        if ((B0 & 0xF8) == 0xF0 && CONT(1) && CONT(2) && CONT(3)) {
            const char32_t CP = (static_cast<char32_t>(B0 & 0x07) << 18) | (BYTE(1) << 12) | (BYTE(2) << 6) | BYTE(3);
            at += 4;
            return CP;
        }
        at += 1;
        return 0xFFFD;
    }

    std::string encode(char32_t cp) {
        std::string out;
        if (cp < 0x80)
            out += static_cast<char>(cp);
        else if (cp < 0x800) {
            out += static_cast<char>(0xC0 | (cp >> 6));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            out += static_cast<char>(0xE0 | (cp >> 12));
            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        } else {
            out += static_cast<char>(0xF0 | (cp >> 18));
            out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        }
        return out;
    }

    bool containsPrivateUse(std::string_view utf8) {
        if (!mayContainPrivateUse(utf8))
            return false;
        for (size_t at = 0; at < utf8.size();)
            if (isPrivateUse(decode(utf8, at)))
                return true;
        return false;
    }

    char32_t single(std::string_view utf8) {
        if (utf8.empty())
            return 0;
        size_t         at = 0;
        const char32_t CP = decode(utf8, at);
        // A trailing VS15/VS16 (text/emoji presentation) is part of the glyph.
        if (at < utf8.size()) {
            size_t         next = at;
            const char32_t VS   = decode(utf8, next);
            if ((VS == 0xFE0E || VS == 0xFE0F) && next == utf8.size())
                return CP;
            return 0;
        }
        return CP;
    }

    std::span<const char32_t> named() {
        return NAMED;
    }

    bool hasSvg(char32_t cp) {
        return find(cp) != nullptr;
    }

    std::string svg(char32_t cp, std::string_view hex, float opacity) {
        const auto* G = find(cp);
        if (!G)
            return {};
        char op[16];
        std::snprintf(op, sizeof(op), "%.3f", std::clamp(opacity, 0.F, 1.F));
        const std::string COLOR{hex};

        std::string out = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 16 16\" width=\"16\" height=\"16\"><g opacity=\"" + std::string(op) + "\">";
        std::string strokes;
        if (*G->stroke)
            strokes += "<path d=\"" + std::string(G->stroke) + "\"/>";
        for (const auto& C : CIRCLES) {
            if (C.cp != cp)
                continue;
            char circle[96];
            std::snprintf(circle, sizeof(circle), "<circle cx=\"%.2f\" cy=\"%.2f\" r=\"%.2f\"/>", C.cx, C.cy, C.r);
            strokes += circle;
        }
        if (!strokes.empty())
            out += "<g fill=\"none\" stroke=\"" + COLOR + "\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\">" + strokes + "</g>";
        if (*G->fill)
            out += "<path fill=\"" + COLOR + "\" d=\"" + std::string(G->fill) + "\"/>";
        out += "</g></svg>";
        return out;
    }

    std::string_view standIn(char32_t cp) {
        const auto* G = find(cp);
        return G ? G->standIn : std::string_view{};
    }

    std::string substitute(std::string_view utf8, const std::function<bool(char32_t)>& fontCovers) {
        if (!mayContainPrivateUse(utf8))
            return std::string{utf8};

        std::string out;
        out.reserve(utf8.size());
        bool changed = false;
        for (size_t at = 0; at < utf8.size();) {
            const size_t   FROM = at;
            const char32_t CP   = decode(utf8, at);
            if (!isPrivateUse(CP) || (fontCovers && fontCovers(CP))) {
                out.append(utf8.substr(FROM, at - FROM));
                continue;
            }
            changed = true;
            out += standIn(CP);
        }
        if (!changed)
            return std::string{utf8};

        // A dropped glyph leaves its padding behind ("Change  " + nothing);
        // collapse runs of spaces and trim the ends so the label stays tidy.
        std::string tidy;
        tidy.reserve(out.size());
        for (const char C : out) {
            if (C == ' ' && (tidy.empty() || tidy.back() == ' '))
                continue;
            tidy += C;
        }
        while (!tidy.empty() && tidy.back() == ' ')
            tidy.pop_back();
        return tidy;
    }
}
