// See PaletteFile.hpp. No Hyprland headers: scripts/palette_file_test.cpp links
// this file on the host.
#include "PaletteFile.hpp"

#include <cctype>
#include <cstdlib>
#include <initializer_list>
#include <regex>
#include <sstream>

namespace ScrollOverview::PaletteFile {

// A "#rrggbb" / "rrggbb" / "#rrggbbaa" string's RGB as opaque ARGB.
std::optional<uint32_t> parseHex(std::string_view v) {
    static const std::regex RE_HEX{R"(^\s*#?([0-9A-Fa-f]{6}))"};
    std::match_results<std::string_view::const_iterator> m;
    if (!std::regex_search(v.begin(), v.end(), m, RE_HEX))
        return std::nullopt;
    return 0xFF000000u | static_cast<uint32_t>(std::strtoul(m[1].str().c_str(), nullptr, 16));
}

// THE SMALLEST JSON THAT READS A PALETTE: objects and arrays flattened to
// "a.b.c" -> string for every STRING leaf (numbers, bools and null are
// skipped; array elements are keyed by index). pywal and matugen exports are
// nothing but nested objects of "#hex" strings, and a full JSON library for
// that is a dependency this plugin does not otherwise have. Malformed input
// stops the walk and keeps what was read.
namespace {
    struct SReader {
        std::string_view                             s;
        size_t                                       i = 0;
        std::unordered_map<std::string, std::string> out;
        int                                          depth = 0;

        void ws() {
            while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i])))
                ++i;
        }
        bool str(std::string& v) {
            if (i >= s.size() || s[i] != '"')
                return false;
            ++i;
            v.clear();
            while (i < s.size() && s[i] != '"') {
                if (s[i] == '\\' && i + 1 < s.size()) {
                    ++i;
                    v += s[i] == 'n' ? '\n' : s[i] == 't' ? '\t' : s[i];
                } else
                    v += s[i];
                ++i;
            }
            if (i >= s.size())
                return false;
            ++i;
            return true;
        }
        bool value(const std::string& path) {
            ws();
            if (i >= s.size() || ++depth > 32)
                return false;
            bool ok = true;
            if (s[i] == '{') {
                ++i;
                ws();
                if (i < s.size() && s[i] == '}')
                    ++i;
                else
                    while (ok) {
                        ws();
                        std::string k;
                        if (!str(k))
                            return false;
                        ws();
                        if (i >= s.size() || s[i] != ':')
                            return false;
                        ++i;
                        ok = value(path.empty() ? k : path + "." + k);
                        ws();
                        if (i < s.size() && s[i] == ',') {
                            ++i;
                            continue;
                        }
                        if (i < s.size() && s[i] == '}') {
                            ++i;
                            break;
                        }
                        return false;
                    }
            } else if (s[i] == '[') {
                ++i;
                ws();
                if (i < s.size() && s[i] == ']')
                    ++i;
                else
                    for (size_t n = 0; ok; ++n) {
                        ok = value(path + "." + std::to_string(n));
                        ws();
                        if (i < s.size() && s[i] == ',') {
                            ++i;
                            continue;
                        }
                        if (i < s.size() && s[i] == ']') {
                            ++i;
                            break;
                        }
                        return false;
                    }
            } else if (s[i] == '"') {
                std::string v;
                if (!str(v))
                    return false;
                out[path] = std::move(v);
            } else {
                while (i < s.size() && s[i] != ',' && s[i] != '}' && s[i] != ']')
                    ++i;
            }
            --depth;
            return ok;
        }
    };

}

std::unordered_map<std::string, std::string> flattenJson(std::string_view text) {
    SReader r{.s = text};
    r.value("");
    return std::move(r.out);
}

// Fill `P` from a flattened pywal or matugen export. Only roles found are set.
static void fromJson(SPalette& P, const std::unordered_map<std::string, std::string>& kv) {
    const auto GET = [&](std::initializer_list<std::string_view> keys) -> std::optional<uint32_t> {
        for (const auto K : keys)
            if (const auto IT = kv.find(std::string{K}); IT != kv.end())
                if (const auto RGB = parseHex(IT->second))
                    return RGB;
        return std::nullopt;
    };
    const auto SET = [](uint32_t& slot, bool& has, std::optional<uint32_t> v) {
        if (v) {
            slot = *v;
            has  = true;
        }
    };

    if (kv.contains("special.background")) {
        // pywal / wallust colors.json: special.{background,foreground},
        // colors.color0..15. color4 is the scheme's blue slot -- what wal
        // templates use as the accent -- color8 its grey, color1 its red.
        SET(P.background, P.hasBg, GET({"special.background"}));
        SET(P.foreground, P.hasFg, GET({"special.foreground"}));
        SET(P.accent, P.hasAccent, GET({"colors.color4", "colors.color2"}));
        SET(P.muted, P.hasMuted, GET({"colors.color8", "colors.color7"}));
        SET(P.urgent, P.hasUrgent, GET({"colors.color1"}));
        return;
    }

    // matugen: Material roles, dark scheme (matugen's default). 2.x nests
    // colors.<mode>.<role>; 3.x nests colors.<role>.<mode>[.color].
    const auto ROLE = [&](std::initializer_list<std::string_view> roles) -> std::optional<uint32_t> {
        for (const auto R : roles) {
            const std::string ROLESTR{R};
            if (const auto V = GET({"colors.dark." + ROLESTR, "colors." + ROLESTR + ".dark", "colors." + ROLESTR + ".dark.color", "colors." + ROLESTR + ".default.color",
                                    "colors." + ROLESTR + ".default", ROLESTR}))
                return V;
        }
        return std::nullopt;
    };
    // GET takes string_views; the temporaries above live to the end of the full
    // expression, which is the whole lookup.
    SET(P.background, P.hasBg, ROLE({"surface", "background"}));
    SET(P.foreground, P.hasFg, ROLE({"on_surface", "on_background"}));
    SET(P.accent, P.hasAccent, ROLE({"primary"}));
    SET(P.muted, P.hasMuted, ROLE({"on_surface_variant", "outline"}));
    SET(P.selection, P.hasSel, ROLE({"primary_container", "secondary_container"}));
    SET(P.urgent, P.hasUrgent, ROLE({"error"}));
}

// colors.toml and anything shaped like it: `key = "#hex"` lines.
SPalette parseKeyValues(std::string_view text, bool& explicitMode) {
    SPalette           P;
    std::istringstream in{std::string{text}};
    static const std::regex RE_KEYVAL{R"(^\s*([a-zA-Z0-9_]+)\s*=\s*[\"']?([^\"'\r\n]+)[\"']?)"};

    std::string line;
    while (std::getline(in, line)) {
        std::smatch match;
        if (!std::regex_search(line, match, RE_KEYVAL))
            continue;

        const auto KEY = match[1].str();
        const auto VAL = match[2].str();

        if (KEY == "mode") {
            P.isLight    = (VAL.find("light") != std::string::npos);
            explicitMode = true;
            continue;
        }

        const auto RGB = parseHex(VAL);
        if (!RGB)
            continue;
        if (KEY == "background") {
            P.background = *RGB;
            P.hasBg      = true;
        } else if (KEY == "foreground") {
            P.foreground = *RGB;
            P.hasFg      = true;
        } else if (KEY == "muted") {
            P.muted    = *RGB;
            P.hasMuted = true;
        } else if (KEY == "accent") {
            P.accent    = *RGB;
            P.hasAccent = true;
        } else if (KEY == "selection") {
            P.selection = *RGB;
            P.hasSel    = true;
        } else if (KEY == "dark_foreground") {
            P.darkForeground = *RGB;
            P.hasDarkFg      = true;
        } else if (KEY == "light_foreground") {
            P.lightForeground = *RGB;
            P.hasLightFg      = true;
        } else if (KEY == "red" || KEY == "urgent") {
            P.urgent    = *RGB;
            P.hasUrgent = true;
        }
    }
    return P;
}


SPalette parse(std::string_view text, bool& explicitMode) {
    explicitMode = false;
    if (const auto AT = text.find_first_not_of(" \t\r\n"); AT != std::string_view::npos && text[AT] == '{') {
        SPalette P;
        fromJson(P, flattenJson(text));
        return P;
    }
    return parseKeyValues(text, explicitMode);
}

}
