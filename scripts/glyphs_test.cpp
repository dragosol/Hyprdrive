// Host test for Glyphs (native port A15): every Private Use Area codepoint the
// plugin's SOURCE names has hyprdrive's own SVG, each SVG renders (librsvg, the
// same engine Hyprgraphics hands SVGs to), and a label never keeps a PUA
// codepoint no font covers -- i.e. a desktop without a Nerd Font gets icons and
// stand-ins, never tofu.
//
// The source scan is the point: a glyph added to Dock.cpp next month without
// an entry in Glyphs.cpp fails HERE, on the build machine, not as a box on
// someone's screen.
#include "../Glyphs.hpp"

#include <librsvg/rsvg.h>

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <regex>
#include <set>
#include <sstream>
#include <string>

using namespace ScrollOverview;

static int g_checks = 0, g_failed = 0;
#define CHECK(c)                                                                                                                                                                   \
    do {                                                                                                                                                                           \
        ++g_checks;                                                                                                                                                                \
        if (!(c)) {                                                                                                                                                                \
            ++g_failed;                                                                                                                                                            \
            std::printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                                                                                                               \
        }                                                                                                                                                                          \
    } while (0)

// The fraction of a 64 px render that is not transparent, and whether any lit
// pixel is the colour asked for.
static double coverage(const std::string& svg, bool* tinted) {
    GError*     err = nullptr;
    RsvgHandle* h   = rsvg_handle_new_from_data(reinterpret_cast<const guint8*>(svg.data()), svg.size(), &err);
    if (!h) {
        if (err)
            g_error_free(err);
        return -1;
    }
    auto*               surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 64, 64);
    auto*               cr   = cairo_create(surf);
    const RsvgRectangle VP{0, 0, 64, 64};
    const bool          OK = rsvg_handle_render_document(h, cr, &VP, nullptr);
    cairo_surface_flush(surf);
    const auto* data   = cairo_image_surface_get_data(surf);
    const int   stride = cairo_image_surface_get_stride(surf);
    int         lit    = 0;
    *tinted            = false;
    for (int y = 0; y < 64; ++y)
        for (int x = 0; x < 64; ++x) {
            const auto* P = data + y * stride + x * 4; // BGRA, premultiplied
            if (P[3] > 16)
                ++lit;
            // #12ab34 at full alpha: B=0x34 G=0xab R=0x12
            if (P[3] == 255 && P[0] == 0x34 && P[1] == 0xab && P[2] == 0x12)
                *tinted = true;
        }
    cairo_destroy(cr);
    cairo_surface_destroy(surf);
    g_object_unref(h);
    return OK ? lit / (64.0 * 64.0) : -1;
}

// Every PUA codepoint written in the plugin's C++ -- as a \uXXXX / \UXXXXXXXX
// escape or as a literal UTF-8 character.
static std::set<char32_t> sourceGlyphs() {
    std::set<char32_t> out;
    static const std::regex ESC{R"(\\u([0-9A-Fa-f]{4})|\\U([0-9A-Fa-f]{8}))"};
    for (const auto& E : std::filesystem::directory_iterator{"."}) {
        const auto P = E.path();
        if (P.extension() != ".cpp" && P.extension() != ".hpp")
            continue;
        if (P.filename() == "Glyphs.cpp")
            continue; // the table itself
        std::ifstream     in{P};
        std::stringstream ss;
        ss << in.rdbuf();
        const auto TEXT = ss.str();
        for (std::sregex_iterator it{TEXT.begin(), TEXT.end(), ESC}, end; it != end; ++it) {
            const auto     HEX = (*it)[1].matched ? (*it)[1].str() : (*it)[2].str();
            const char32_t CP  = static_cast<char32_t>(std::stoul(HEX, nullptr, 16));
            if (Glyphs::isPrivateUse(CP))
                out.insert(CP);
        }
        for (size_t at = 0; at < TEXT.size();) {
            const char32_t CP = Glyphs::decode(TEXT, at);
            if (Glyphs::isPrivateUse(CP))
                out.insert(CP);
        }
    }
    return out;
}

int main() {
    // 1. The source's glyphs are all in the table, with art.
    const auto USED = sourceGlyphs();
    CHECK(USED.size() >= 30); // the scan itself works (37 at the time of writing)
    for (const char32_t CP : USED) {
        const bool HAS = Glyphs::hasSvg(CP);
        if (!HAS)
            std::printf("source names U+%04X with no Glyphs.cpp entry\n", static_cast<unsigned>(CP));
        CHECK(HAS);
    }

    // 2. Every entry renders, in the colour asked, and is line art -- not a
    //    blank and not a filled square.
    for (const char32_t CP : Glyphs::named()) {
        const auto SVG = Glyphs::svg(CP, "#12ab34");
        CHECK(SVG.starts_with("<svg") && SVG.find("#12ab34") != std::string::npos);
        bool         tinted = false;
        const double C      = coverage(SVG, &tinted);
        if (!(C > 0.02 && C < 0.75) || !tinted)
            std::printf("U+%04X coverage %.3f tinted %d\n", static_cast<unsigned>(CP), C, tinted);
        CHECK(C > 0.02 && C < 0.75);
        CHECK(tinted);
    }
    // Opacity is baked in, the way renderText bakes a colour's alpha.
    CHECK(Glyphs::svg(0xF054, "#ffffff", 0.45F).find("opacity=\"0.450\"") != std::string::npos);
    CHECK(Glyphs::svg(0xE0B0, "#ffffff").empty()); // a powerline arrow: not ours
    CHECK(!Glyphs::hasSvg(0xF8FF));

    // 3. UTF-8 helpers.
    CHECK(Glyphs::single("") == 0xF054);
    CHECK(Glyphs::single("️") == 0xF054);
    CHECK(Glyphs::single("ab") == 0);
    CHECK(Glyphs::single("") == 0);
    CHECK(Glyphs::single("\U000F0001") == 0xF0001);
    CHECK(Glyphs::encode(0xF054) == "" && Glyphs::encode(0xF0001) == "\U000F0001" && Glyphs::encode('a') == "a");
    {
        const std::string BAD = "\xEF\x80"; // truncated
        size_t            at  = 0;
        int               n   = 0;
        while (at < BAD.size() && n < 10) {
            Glyphs::decode(BAD, at);
            ++n;
        }
        CHECK(at == BAD.size() && n == 2);
    }
    CHECK(!Glyphs::mayContainPrivateUse("plain ascii, café, ↑"));
    CHECK(Glyphs::containsPrivateUse("Change  "));
    CHECK(!Glyphs::containsPrivateUse("ﬁ")); // U+FB01 "fi": EF lead byte, not PUA

    // 4. substitute(): no font -> stand-ins or nothing, tidy spacing.
    const auto NOFONT = [](char32_t) { return false; };
    const auto ALL    = [](char32_t) { return true; };
    CHECK(Glyphs::substitute("Change  ", NOFONT) == "Change ›");
    CHECK(Glyphs::substitute("3  ", NOFONT) == "3 ›");
    CHECK(Glyphs::substitute("   Drag here to exit scratchpad", NOFONT) == "↑ Drag here to exit scratchpad");
    CHECK(Glyphs::substitute("Name  ", NOFONT) == "Name ↕");
    CHECK(Glyphs::substitute("", NOFONT).empty());
    CHECK(Glyphs::substitute("a  b", NOFONT) == "a b");
    CHECK(Glyphs::substitute("Change  ", ALL) == "Change  "); // covered: untouched, spacing too
    CHECK(Glyphs::substitute("no glyphs  here", NOFONT) == "no glyphs  here");
    for (const char32_t CP : Glyphs::named()) {
        const auto OUT = Glyphs::substitute("x " + Glyphs::encode(CP) + " y", NOFONT);
        CHECK(!Glyphs::containsPrivateUse(OUT));
        // A stand-in is WGL4-plain: BMP, below the PUA, never itself a glyph.
        for (size_t at = 0; at < Glyphs::standIn(CP).size();) {
            const char32_t S = Glyphs::decode(Glyphs::standIn(CP), at);
            CHECK(S < 0x2200);
        }
    }

    std::printf("glyphs_test: %zu source glyphs, %zu drawn, %d checks, %d failed\n", USED.size(), Glyphs::named().size(), g_checks, g_failed);
    return g_failed ? 1 : 0;
}
