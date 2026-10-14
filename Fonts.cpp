// See Fonts.hpp. fontconfig only: scripts/fonts_test.cpp links this file on
// the host with Glyphs.cpp.
#include "Fonts.hpp"
#include "Glyphs.hpp"

#include <fontconfig/fontconfig.h>

#include <algorithm>
#include <cctype>
#include <string>
#include <tuple>
#include <unordered_map>

namespace {
    // The folder glyph: in every Font Awesome / Nerd Fonts release, and in no
    // legacy ligature table (U+F001/U+F002 are "fi"/"fl" in Apple's PUA, which
    // Ubuntu and Liberation still carry). It pre-filters FcFontList so the
    // scoring below only ever walks icon fonts.
    constexpr char32_t ANCHOR = 0xF07C;

    // The family the plugin always asked for. Preferred on a tie so Omarchy,
    // which installs it, keeps exactly the glyphs it had.
    constexpr std::string_view LEGACY_FAMILY = "JetBrainsMono Nerd Font";

    struct SIconChoice {
        std::string family;
        FcCharSet*  charset = nullptr; // owned (FcCharSetCopy)
        size_t      covered = 0;
    };

    std::unordered_map<std::string, SIconChoice> g_choices; // setting -> choice

    bool fcReady() {
        static const bool OK = FcInit() == FcTrue;
        return OK;
    }

    std::string lower(std::string_view s) {
        std::string out{s};
        std::ranges::transform(out, out.begin(), [](unsigned char c) { return std::tolower(c); });
        return out;
    }

    // Among equally-covering candidates: the legacy family, then a proportional
    // Nerd Font (full-size icons), then "Nerd Font Propo", the Symbols-only
    // font, the Mono variants (icons squeezed to one cell), anything else.
    int preference(std::string_view family) {
        if (family == LEGACY_FAMILY)
            return 0;
        const auto L = lower(family);
        if (L.ends_with("nerd font"))
            return 1;
        if (L.ends_with("nerd font propo"))
            return 2;
        if (L.find("symbols") != std::string::npos && L.find("nerd") != std::string::npos)
            return 3;
        if (L.find("nerd font mono") != std::string::npos)
            return 4;
        return 5;
    }

    size_t coverage(FcCharSet* cs) {
        size_t n = 0;
        for (const char32_t CP : ScrollOverview::Glyphs::named())
            n += FcCharSetHasChar(cs, CP) ? 1 : 0;
        return n;
    }

    // FcFontList with `family` and/or the anchor glyph; calls `each(family,
    // charset)` per face. Every face, not one per family: a family's Bold face
    // can cover what its Regular lacks, and the regular face is what gets drawn
    // -- the minimum over its faces is the honest answer, see detect().
    template <typename F>
    void listFaces(const char* family, bool anchor, F&& each) {
        if (!fcReady())
            return;
        FcPattern* pat = FcPatternCreate();
        if (family)
            FcPatternAddString(pat, FC_FAMILY, reinterpret_cast<const FcChar8*>(family));
        FcCharSet* need = nullptr;
        if (anchor) {
            need = FcCharSetCreate();
            FcCharSetAddChar(need, ANCHOR);
            FcPatternAddCharSet(pat, FC_CHARSET, need);
        }
        FcObjectSet* os = FcObjectSetBuild(FC_FAMILY, FC_CHARSET, nullptr);
        FcFontSet*   fs = FcFontList(nullptr, pat, os);
        if (fs) {
            for (int i = 0; i < fs->nfont; ++i) {
                FcChar8*   fam = nullptr;
                FcCharSet* cs  = nullptr;
                if (FcPatternGetString(fs->fonts[i], FC_FAMILY, 0, &fam) != FcResultMatch || !fam ||
                    FcPatternGetCharSet(fs->fonts[i], FC_CHARSET, 0, &cs) != FcResultMatch || !cs)
                    continue;
                each(std::string{reinterpret_cast<const char*>(fam)}, cs);
            }
            FcFontSetDestroy(fs);
        }
        FcObjectSetDestroy(os);
        if (need)
            FcCharSetDestroy(need);
        FcPatternDestroy(pat);
    }

    SIconChoice detect(const char* onlyFamily) {
        // family -> (worst face coverage, that face's charset)
        struct SCand {
            size_t     covered = SIZE_MAX;
            FcCharSet* charset = nullptr; // borrowed until the copy below
        };
        std::unordered_map<std::string, SCand> cands;
        SIconChoice                             best;

        listFaces(onlyFamily, /* anchor */ onlyFamily == nullptr, [&](const std::string& family, FcCharSet* cs) {
            auto&        c = cands[family];
            const size_t N = coverage(cs);
            if (N < c.covered) {
                c.covered = N;
                if (c.charset)
                    FcCharSetDestroy(c.charset);
                c.charset = FcCharSetCopy(cs);
            }
        });

        const size_t WANT = ScrollOverview::Glyphs::named().size();
        const auto   NEED = static_cast<size_t>(static_cast<double>(WANT) * ScrollOverview::Fonts::MIN_COVERAGE + 0.999);
        for (auto& [family, c] : cands) {
            // The legacy family whenever it qualifies at all (Omarchy: the
            // exact glyphs it always drew), then the most coverage, then
            // preference(), then the name -- a total order, so the choice
            // does not depend on FcFontList's order.
            const auto RANK = [](const std::string& fam, size_t covered) {
                return std::make_tuple(fam == LEGACY_FAMILY ? 0 : 1, -static_cast<long>(covered), preference(fam), fam);
            };
            const bool OK     = c.covered != SIZE_MAX && c.covered >= NEED;
            const bool BETTER = OK && (best.family.empty() || RANK(family, c.covered) < RANK(best.family, best.covered));
            if (BETTER) {
                if (best.charset)
                    FcCharSetDestroy(best.charset);
                best.family  = family;
                best.covered = c.covered;
                best.charset = c.charset;
                c.charset    = nullptr;
            }
        }
        for (auto& [_, c] : cands)
            if (c.charset)
                FcCharSetDestroy(c.charset);
        return best;
    }

    const SIconChoice& choice(std::string_view setting) {
        const std::string KEY = setting.empty() ? std::string{"auto"} : std::string{setting};
        if (const auto IT = g_choices.find(KEY); IT != g_choices.end())
            return IT->second;

        SIconChoice c;
        if (KEY == "builtin" || KEY == "none") {
            // no font at all
        } else if (KEY != "auto") {
            c = detect(KEY.c_str());
            if (c.family.empty())
                c = detect(nullptr);
        } else
            c = detect(nullptr);
        return g_choices.emplace(KEY, std::move(c)).first->second;
    }
}

namespace ScrollOverview::Fonts {
    std::string matchFamily(const std::string& pattern) {
        if (pattern.empty() || !fcReady())
            return {};
        FcPattern* pat = FcNameParse(reinterpret_cast<const FcChar8*>(pattern.c_str()));
        if (!pat)
            return {};
        FcConfigSubstitute(nullptr, pat, FcMatchPattern);
        FcDefaultSubstitute(pat);
        FcResult   res   = FcResultNoMatch;
        FcPattern* match = FcFontMatch(nullptr, pat, &res);
        std::string out;
        FcChar8*    fam = nullptr;
        if (match && FcPatternGetString(match, FC_FAMILY, 0, &fam) == FcResultMatch && fam)
            out = reinterpret_cast<const char*>(fam);
        if (match)
            FcPatternDestroy(match);
        FcPatternDestroy(pat);
        return out;
    }

    bool installed(const std::string& family) {
        bool found = false;
        if (!family.empty())
            listFaces(family.c_str(), false, [&](const std::string&, FcCharSet*) { found = true; });
        return found;
    }

    const std::string& iconFamily(std::string_view setting) {
        return choice(setting).family;
    }

    bool iconCovers(std::string_view setting, char32_t cp) {
        const auto& C = choice(setting);
        return C.charset && FcCharSetHasChar(C.charset, cp);
    }

    size_t iconCoverage(std::string_view setting) {
        return choice(setting).covered;
    }

    void reset() {
        for (auto& [_, c] : g_choices)
            if (c.charset)
                FcCharSetDestroy(c.charset);
        g_choices.clear();
    }
}
