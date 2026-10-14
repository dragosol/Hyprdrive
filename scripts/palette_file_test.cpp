// Host test for PaletteFile (native port A12): the three palette shapes
// theme:palette_file accepts -- Omarchy's colors.toml, a pywal colors.json and
// a matugen export (2.x and 3.x nesting) -- each land on the right roles, and
// a role a file does not name stays unset for Config.cpp to derive.
#include "../PaletteFile.hpp"

#include <cstdio>
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

int main() {
    bool mode = false;

    // Omarchy's colors.toml (trimmed from a real theme).
    {
        const auto P = PaletteFile::parse("accent = \"#e5a50a\"\nbackground = \"#14161c\"\nforeground = \"#f2efe6\"\nselection = \"#3b3524\"\n"
                                          "red = \"#ff5f5f\"\nlight_foreground = '#aaaaaa'\n# a comment = \"#000000\"\nmode = \"dark\"\n",
                                          mode);
        CHECK(mode && !P.isLight);
        CHECK(P.hasAccent && P.accent == 0xFFe5a50a);
        CHECK(P.hasBg && P.background == 0xFF14161c);
        CHECK(P.hasFg && P.foreground == 0xFFf2efe6);
        CHECK(P.hasSel && P.selection == 0xFF3b3524);
        CHECK(P.hasUrgent && P.urgent == 0xFFff5f5f);
        CHECK(P.hasLightFg && P.lightForeground == 0xFFaaaaaa);
        CHECK(!P.hasMuted && !P.hasDarkFg);
    }
    {
        const auto P = PaletteFile::parseKeyValues("background=\"#fafafa\"\nmode = light\n", mode);
        CHECK(mode && P.isLight && P.hasBg);
    }

    // pywal colors.json.
    {
        const auto P = PaletteFile::parse(R"({
            "wallpaper": "/x.png", "alpha": "100",
            "special": { "background": "#0f1d1a", "foreground": "#d8efe6", "cursor": "#d8efe6" },
            "colors": { "color0": "#0f1d1a", "color1": "#e0605a", "color4": "#3fc1c9", "color8": "#6a8a80" }
        })",
                                          mode);
        CHECK(!mode);
        CHECK(P.hasBg && P.background == 0xFF0f1d1a);
        CHECK(P.hasFg && P.foreground == 0xFFd8efe6);
        CHECK(P.hasAccent && P.accent == 0xFF3fc1c9);
        CHECK(P.hasMuted && P.muted == 0xFF6a8a80);
        CHECK(P.hasUrgent && P.urgent == 0xFFe0605a);
        CHECK(!P.hasSel); // derived by Config.cpp
    }

    // matugen 2.x: colors.<mode>.<role>, dark wins.
    {
        const auto P = PaletteFile::parse(R"({"colors": {
            "light": {"primary": "#111111", "surface": "#fefefe"},
            "dark":  {"primary": "#a8c7fa", "surface": "#111318", "on_surface": "#e2e2e9", "outline": "#8e9099",
                      "primary_container": "#284777", "error": "#ffb4ab"}
        }})",
                                          mode);
        CHECK(P.hasAccent && P.accent == 0xFFa8c7fa);
        CHECK(P.hasBg && P.background == 0xFF111318);
        CHECK(P.hasFg && P.foreground == 0xFFe2e2e9);
        CHECK(P.hasMuted && P.muted == 0xFF8e9099);
        CHECK(P.hasSel && P.selection == 0xFF284777);
        CHECK(P.hasUrgent && P.urgent == 0xFFffb4ab);
    }

    // matugen 3.x: colors.<role>.<mode>.color, with "default" beside them.
    {
        const auto P = PaletteFile::parse(R"({"image": "x", "mode": "dark", "colors": {
            "primary": {"dark": {"color": "#ffb3b0"}, "default": {"color": "#ffb3b0"}, "light": {"color": "#904a47"}},
            "surface": {"dark": {"color": "#1a1111"}, "light": {"color": "#fff8f7"}},
            "on_surface_variant": {"dark": {"color": "#d8c2c0"}}
        }})",
                                          mode);
        CHECK(P.hasAccent && P.accent == 0xFFffb3b0);
        CHECK(P.hasBg && P.background == 0xFF1a1111);
        CHECK(P.hasMuted && P.muted == 0xFFd8c2c0);
        CHECK(!P.hasFg);
    }

    // Robustness: garbage and truncation never throw, never invent a role.
    {
        const auto P = PaletteFile::parse("{\"colors\": {\"dark\": {\"primary\": \"#a8c7fa\"", mode);
        CHECK(P.hasAccent && P.accent == 0xFFa8c7fa); // kept what was read
        const auto Q = PaletteFile::parse("not a palette at all\n\x01\x02", mode);
        CHECK(!Q.hasBg && !Q.hasFg && !Q.hasAccent);
        const auto R = PaletteFile::parse("{[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[", mode);
        CHECK(!R.hasAccent);
    }
    CHECK(PaletteFile::parseHex("#A1b2C3") == 0xFFa1b2c3u);
    CHECK(PaletteFile::parseHex("a1b2c3ff") == 0xFFa1b2c3u);
    CHECK(!PaletteFile::parseHex("rgb(1,2,3)"));
    CHECK(PaletteFile::flattenJson(R"({"a": {"b": ["x", {"c": "y"}], "n": 3, "t": true}})").at("a.b.1.c") == "y");

    std::printf("palette_file_test: %d checks, %d failed\n", g_checks, g_failed);
    return g_failed ? 1 : 0;
}
