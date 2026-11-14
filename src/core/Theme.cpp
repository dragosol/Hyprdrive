#include "ConfigParts.hpp"
#include "TextScale.hpp"
using namespace ConfigDetail;

namespace Hyprdrive::Config {

using namespace ConfigPart;

static CHyprColor colorFromArgb(uint32_t argb, float alphaOverride = -1.F) {
    const float a = alphaOverride >= 0.F ? alphaOverride : sc<float>((argb >> 24) & 0xFF) / 255.F;
    return CHyprColor{sc<float>((argb >> 16) & 0xFF) / 255.F, sc<float>((argb >> 8) & 0xFF) / 255.F, sc<float>(argb & 0xFF) / 255.F, a};
}

// ---- THE PALETTE (native port A12/A13, P2-8) --------------------------------
//
// Six roles -- background, foreground, muted, accent, selection, urgent -- and
// the first answer wins, per role (the keys' registration, above, has the list):
// theme:<role> key > theme:palette_file > Omarchy's colors.toml (on Omarchy
// only) > derived from Hyprland's live values. The FILE half is SPalette: one
// parse of whichever file applies, cached on its path and mtime.
//
// Omarchy's colors.toml keeps the exact semantics every earlier build had: a
// role the file omits takes the fixed default below (the old
// SOmarchyThemeColors initialisers), and the file counts as having it. A
// palette_file does NOT: a role it omits falls through to the derivation, so a
// pywal file with no "selection" still gets a sensible one.
using SPalette = Hyprdrive::PaletteFile::SPalette;

static float relLuma(const CHyprColor& c) {
    return (0.2126F * c.r) + (0.7152F * c.g) + (0.0722F * c.b);
}

static float lumaDelta(const CHyprColor& a, const CHyprColor& b) {
    return std::abs(relLuma(a) - relLuma(b));
}

static CHyprColor readableOn(const CHyprColor& bg, std::initializer_list<CHyprColor> prefs) {
    CHyprColor best{};
    float      bestD = -1.F;
    for (const auto& p : prefs) {
        const float d = lumaDelta(p, bg);
        if (d > bestD) {
            bestD = d;
            best  = p;
        }
    }
    if (bestD >= 0.28F)
        return best;
    return relLuma(bg) <= 0.55F ? CHyprColor{1.F, 1.F, 1.F, 1.F} : CHyprColor{0.12F, 0.12F, 0.12F, 1.F};
}

static CHyprColor mixColor(const CHyprColor& a, const CHyprColor& b, float t) {
    return CHyprColor{a.r * (1.F - t) + b.r * t, a.g * (1.F - t) + b.g * t, a.b * (1.F - t) + b.b * t, 1.F};
}

// How often the theme file is looked at, at most. palette() sits behind
// six colour accessors and every one of those is read per card per frame, so
// the mtime check ran -- getenv, a path concatenation and a stat() -- thousands
// of times a second to notice a file the user changes by hand. Same number and
// the same reasoning as the dock's FAVORITES_POLL_MS.
static constexpr float THEME_POLL_MS = 500.F;

void invalidateThemeCache() {
    ++g_themeGeneration;
}

uint64_t themeGeneration() {
    return g_themeGeneration;
}

// A plugin colour key's value when it is SET (alpha > 0), read through the
// cached handle. Before registration there is no key to read -- binding one
// aborts Hyprland (Config.hpp, earlyPluginKey) -- so it is simply unset.
static std::optional<CHyprColor> explicitColor(std::string_view key, CConfigValue<Hyprlang::INT>** slot) {
    if (!g_pluginKeysRegistered)
        return std::nullopt;
    if (!*slot)
        *slot = &valueRef<Hyprlang::INT>(key);
    const uint32_t ARGB = sc<uint32_t>(***slot);
    if ((ARGB >> 24) == 0)
        return std::nullopt;
    return colorFromArgb(ARGB);
}

#define THEME_KEY(NAME)                                                                                                                                                            \
    ([] {                                                                                                                                                                          \
        static CConfigValue<Hyprlang::INT>* slot = nullptr;                                                                                                                       \
        return explicitColor("plugin:hyprdrive:theme:" NAME, &slot);                                                                                                               \
    }())

// The value of a plugin string key, or `fallback` before registration.
static std::string pluginString(std::string_view key, std::string_view fallback = {}) {
    if (!g_pluginKeysRegistered)
        return std::string{fallback};
    auto v = getValue<std::string>(key);
    if (v == STRVAL_EMPTY)
        v.clear();
    return v;
}

static std::string expandHome(std::string path) {
    if (path.starts_with("~/")) {
        const char* HOME = std::getenv("HOME");
        path             = (HOME && *HOME) ? std::string{HOME} + path.substr(1) : std::string{};
    }
    return path;
}

// Which file the palette comes from: theme:palette_file when set, else
// Omarchy's colors.toml ON OMARCHY ONLY (Integration.hpp -- fedora's hyprtest
// has the state files and no Omarchy, and a vanilla box that once had Omarchy
// keeps them), else none. `omarchy` says which rules apply to what is read.
static std::string paletteFilePath(bool& omarchy) {
    omarchy = false;
    if (auto file = expandHome(pluginString("plugin:hyprdrive:theme:palette_file")); !file.empty())
        return file;
    if (!Hyprdrive::Integration::omarchy())
        return {};
    omarchy                 = true;
    const char* const STATE = std::getenv("XDG_STATE_HOME");
    const char* const HOME  = std::getenv("HOME");
    return (STATE && *STATE) ? std::string{STATE} + "/omarchy/current/theme/colors.toml" :
        (HOME && *HOME)      ? std::string{HOME} + "/.local/state/omarchy/current/theme/colors.toml" :
                               std::string{};
}

// Omarchy writes the active palette into colors.toml on `omarchy theme set`
// and reloads Hyprland. Cached on mtime so a frame does not reopen the file,
// and the mtime itself behind THEME_POLL_MS so a frame does not stat it either.
//
// `last` is what the previous FULL check resolved to, and the throttled path
// returns exactly that -- handing back `cachedTheme` would resurrect a palette
// whose file has since gone away.
static const SPalette& palette() {
    static const SPalette  NONE{};
    static SPalette        cachedTheme;
    static const SPalette* last = &NONE;
    static std::string     cachedPath;
    static time_t          cachedMtime = 0;
    static Time::steady_tp checkedAt{};
    static uint64_t        seenGeneration = 0;

    const auto NOW = Time::steadyNow();
    if (seenGeneration == g_themeGeneration && std::chrono::duration<float, std::milli>(NOW - checkedAt).count() < THEME_POLL_MS)
        return *last;

    // A reload can change WHICH file applies (palette_file, the integration),
    // not just its contents: a new generation re-parses whatever it lands on.
    const bool NEWGEN = seenGeneration != g_themeGeneration;
    checkedAt         = NOW;
    seenGeneration    = g_themeGeneration;
    last              = &NONE;

    bool              omarchy = false;
    const std::string PATH    = paletteFilePath(omarchy);
    if (PATH.empty())
        return NONE;

    struct stat st {};
    if (stat(PATH.c_str(), &st) != 0)
        return NONE;

    last = &cachedTheme;

    if (!NEWGEN && cachedTheme.valid && cachedPath == PATH && cachedMtime == st.st_mtime)
        return cachedTheme;

    cachedTheme = {};
    cachedPath  = PATH;
    cachedMtime = st.st_mtime;

    std::ifstream in{PATH};
    if (!in)
        return cachedTheme;

    bool              explicitMode = false;
    const std::string TEXT{std::istreambuf_iterator<char>{in}, std::istreambuf_iterator<char>{}};
    // Omarchy's file is colors.toml by definition; a palette_file may be any
    // of the three shapes (PaletteFile.hpp sniffs which).
    cachedTheme = omarchy ? Hyprdrive::PaletteFile::parseKeyValues(TEXT, explicitMode) : Hyprdrive::PaletteFile::parse(TEXT, explicitMode);

    if (!explicitMode && cachedTheme.hasBg) {
        const float r = sc<float>((cachedTheme.background >> 16) & 0xFF) / 255.F;
        const float g = sc<float>((cachedTheme.background >> 8) & 0xFF) / 255.F;
        const float b = sc<float>(cachedTheme.background & 0xFF) / 255.F;
        const float LUMA = (0.2126F * r) + (0.7152F * g) + (0.0722F * b);
        cachedTheme.isLight = (LUMA > 0.55F);
    }

    if (omarchy) {
        // The old colors.toml rules, verbatim: a missing fg/muted follows the
        // mode, and every role counts as present (with its fixed default).
        if (!cachedTheme.hasFg)
            cachedTheme.foreground = cachedTheme.isLight ? 0xFF141414u : 0xFFFAFCFBu;
        if (!cachedTheme.hasMuted)
            cachedTheme.muted = cachedTheme.isLight ? 0xFF606060u : 0xFF8A8588u;
        cachedTheme.hasBg = cachedTheme.hasFg = cachedTheme.hasMuted = cachedTheme.hasAccent = cachedTheme.hasSel = true;
    } else if (!explicitMode && !cachedTheme.hasBg) {
        // A palette file with no background: its light/dark is the plate's.
        const auto BG       = colorFromArgb(sc<uint32_t>(*valueRef<Hyprlang::INT>("misc:background_color")));
        cachedTheme.isLight = relLuma(BG) > 0.55F;
    }

    cachedTheme.valid = true;
    return cachedTheme;
}

// Is a Hyprland key the user's, or still its compiled-in default? Asked of the
// config manager (SConfigOptionReply::setByUser) once per theme generation, not
// per frame: the accent sits under every tile ring. One static slot per call
// site, so the hot path is a compare, not a string-keyed lookup.
struct SSetByUser {
    const char* key;
    uint64_t    generation = 0;
    bool        value      = false;
};

static bool setByUser(SSetByUser& s) {
    if (s.generation != g_themeGeneration) {
        s.generation = g_themeGeneration;
        s.value      = false;
        if (const auto& MGR = ::Config::mgr())
            s.value = MGR->getConfigValue(s.key).setByUser;
    }
    return s.value;
}

// The plate colour the text has to read against: the explicit/file background
// when there is one, else the dock's (which is misc:background_color unless
// dock:background_color pins it). Alpha is the plate's; contrast ignores it.
static CHyprColor plateBackground() {
    if (const auto BG = THEME_KEY("background"))
        return BG->modifyA(1.F);
    if (const auto& P = palette(); P.valid && P.hasBg)
        return colorFromArgb(P.background, 1.F);
    return dockBackgroundColor();
}

bool isLightTheme() {
    if (THEME_KEY("background"))
        return relLuma(plateBackground()) > 0.55F;
    const auto& P = palette();
    if (P.valid)
        return P.isLight;
    const auto BG = dockBackgroundColor();
    const float LUMA = (0.2126F * BG.r) + (0.7152F * BG.g) + (0.0722F * BG.b);
    return LUMA > 0.55F;
}

CHyprColor themeForeground() {
    if (const auto FG = THEME_KEY("foreground"))
        return FG->modifyA(1.F);
    const auto& P = palette();
    if (P.valid && P.hasFg)
        return colorFromArgb(P.foreground, 1.F);
    // Vanilla: the groupbar title colour is the one text colour Hyprland's own
    // config carries -- the user's, when they set it and it reads on the plate.
    static SSetByUser GROUPTEXT{"group:groupbar:text_color"};
    if (setByUser(GROUPTEXT)) {
        static auto& TEXT = valueRef<Hyprlang::INT>("group:groupbar:text_color");
        const auto   C    = colorFromArgb(sc<uint32_t>(*TEXT), 1.F);
        if (lumaDelta(C, plateBackground()) >= 0.28F)
            return C;
    }
    return isLightTheme() ? CHyprColor{0.08F, 0.08F, 0.08F, 1.F} : CHyprColor{1.F, 1.F, 1.F, 1.F};
}

CHyprColor themeMutedText() {
    if (const auto M = THEME_KEY("muted"))
        return M->modifyA(1.F);
    const auto& T  = palette();
    const auto  BG = plateBackground();
    const auto  FG = themeForeground();

    // `muted` in colors.toml is often a surface/overlay, not body text. Prefer
    // light_foreground (Omarchy subtext) then dark_foreground, then muted —
    // whichever still contrasts with the plate. Off Omarchy with no palette,
    // the user's inactive border is the one grey Hyprland has to offer.
    //
    // A fixed array, not a vector: three candidates at most, and this is read
    // once per label per frame -- the vector was a heap allocation to hold
    // 48 bytes of colour.
    static SSetByUser         INACTIVE{"general:col.inactive_border"};
    std::array<CHyprColor, 3> cands{};
    size_t                    nCands = 0;
    if (T.valid && T.hasLightFg)
        cands[nCands++] = colorFromArgb(T.lightForeground, 1.F);
    if (T.valid && T.hasDarkFg)
        cands[nCands++] = colorFromArgb(T.darkForeground, 1.F);
    if (T.valid && T.hasMuted)
        cands[nCands++] = colorFromArgb(T.muted, 1.F);
    else if (setByUser(INACTIVE))
        cands[nCands++] = restingBorderColor().modifyA(1.F);

    CHyprColor best = FG;
    float      bestD = -1.F;
    for (const auto& c : std::span{cands.data(), nCands}) {
        const float vsBg = lumaDelta(c, BG);
        if (vsBg < 0.22F)
            continue;
        if (vsBg > bestD) {
            bestD = vsBg;
            best  = c;
        }
    }
    if (bestD >= 0.22F)
        return best;

    const CHyprColor MIX{FG.r * 0.72F + BG.r * 0.28F, FG.g * 0.72F + BG.g * 0.28F, FG.b * 0.72F + BG.b * 0.28F, 1.F};
    if (lumaDelta(MIX, BG) >= 0.22F)
        return MIX;
    return FG;
}

CHyprColor themeAccent() {
    if (const auto A = THEME_KEY("accent"))
        return A->modifyA(1.F);
    const auto& T = palette();
    if (T.valid && T.hasAccent)
        return colorFromArgb(T.accent, 1.F);
    return highlightColor();
}

CHyprColor themeHeading() {
    return readableOn(plateBackground(), {themeAccent(), themeForeground()});
}

CHyprColor themeSelection() {
    if (const auto S = THEME_KEY("selection"))
        return S->modifyA(1.F);
    const auto& T = palette();
    if (T.valid && T.hasSel)
        return colorFromArgb(T.selection, 1.F);
    return highlightColor().modifyA(0.35F);
}

// WCAG contrast between two opaque colours (1 = identical, 21 = black/white).
static float contrastRatio(const CHyprColor& a, const CHyprColor& b) {
    const auto LIN = [](float c) { return c <= 0.04045F ? c / 12.92F : std::pow((c + 0.055F) / 1.055F, 2.4F); };
    const auto L   = [&](const CHyprColor& c) { return (0.2126F * LIN(c.r)) + (0.7152F * LIN(c.g)) + (0.0722F * LIN(c.b)); };
    const float LA = L(a), LB = L(b);
    return (std::max(LA, LB) + 0.05F) / (std::min(LA, LB) + 0.05F);
}

// THE SELECTED ROW HAS TO STAND OUT (user, 2026-10-24: "the search results
// selection ... is nearly indistinguishable from the search results
// background"). A theme's `selection` is made for selected TEXT -- bright text
// on it says what is selected -- so it is often a shade off the background
// (Omarchy's grey themes: #343d41 on #101315, 1.7:1). It was taken whenever its
// LUMA differed by 0.10; now it must reach SELECTED_MIN contrast against the
// plate, which is translucent over blur on screen and so reads weaker still.
// Short of that, the accent is mixed into the plate until the mix does; a theme
// whose accent is itself near the plate gets a foreground wash.
static constexpr float SELECTED_MIN = 1.9F;

CHyprColor themeSelectedFill() {
    const auto BG  = plateBackground();
    const auto SEL = themeSelection();
    if (contrastRatio(SEL, BG) >= SELECTED_MIN)
        return SEL.modifyA(0.92F);
    const auto ACCENT = themeAccent();
    for (const float T : {0.45F, 0.6F, 0.75F, 0.9F})
        if (const auto MIX = mixColor(BG, ACCENT, T); contrastRatio(MIX, BG) >= SELECTED_MIN)
            return MIX.modifyA(0.92F);
    const auto FG = themeForeground();
    return CHyprColor{FG.r, FG.g, FG.b, 0.26F};
}

// A ring around the selected row when its fill alone is quiet (under 3:1
// against the plate): the accent, or whichever of accent and foreground reads
// on the plate. Alpha 0 = no ring.
CHyprColor themeSelectedRing() {
    const auto BG   = plateBackground();
    const auto FILL = themeSelectedFill();
    const auto SOLID = FILL.a >= 0.6F ? FILL.modifyA(1.F) : mixColor(BG, FILL.modifyA(1.F), FILL.a);
    if (contrastRatio(SOLID, BG) >= 3.F)
        return CHyprColor{0.F, 0.F, 0.F, 0.F};
    return readableOn(BG, {themeAccent(), themeForeground()}).modifyA(0.9F);
}

CHyprColor themeSelectedText() {
    const auto FILL = themeSelectedFill();
    // Approximate the blended plate: opaque-ish fill vs translucent fg wash.
    const CHyprColor BG = FILL.a >= 0.6F ? FILL : CHyprColor{
        FILL.r * FILL.a, FILL.g * FILL.a, FILL.b * FILL.a, 1.F
    };
    return readableOn(BG, {themeForeground(), themeAccent()});
}

CHyprColor themeUrgent() {
    if (const auto U = THEME_KEY("urgent"))
        return U->modifyA(1.F);
    const auto& T = palette();
    if (T.valid && T.hasUrgent)
        return colorFromArgb(T.urgent, 1.F);
    return CHyprColor{0.95F, 0.35F, 0.35F, 1.F};
}

CHyprColor highlightColor() {
    // The accent is read a dozen times a frame per monitor -- every tile ring,
    // every strip cell, every selected row. Through getValue<CGradientValueData>
    // each of those was two full copies of a vector-owning gradient; the handles
    // are resolved once and only the ONE colour that is wanted is copied out.
    static auto& HIGHLIGHT = valueRef<::Config::IComplexConfigValue>("plugin:hyprdrive:col_highlight");
    if (const auto* G = gradientPtr(HIGHLIGHT); G && !G->m_colors.empty() && G->m_colors[0].a > 0.001F)
        return G->m_colors[0];

    if (const auto A = THEME_KEY("accent"))
        return A->modifyA(1.F);

    // The window border -- when it is a CHOICE. Hyprland's compiled-in
    // active_border is plain white, and a config that never set it drew every
    // card, plate and dock outline in the overview as a white frame (the
    // "plain white outline frames" of docs/native/SETUP-REPORT.md). Omarchy
    // always sets it, so this changes nothing there.
    static auto& ACCENT = valueRef<::Config::IComplexConfigValue>("general:col.active_border");
    const auto*  G      = gradientPtr(ACCENT);
    static SSetByUser ACTIVESET{"general:col.active_border"};
    if (G && !G->m_colors.empty() && (Hyprdrive::Integration::omarchy() || setByUser(ACTIVESET)))
        return G->m_colors[0];

    if (const auto& T = palette(); T.valid && T.hasAccent)
        return colorFromArgb(T.accent, 1.F);

    // Nothing anywhere names an accent: a quiet one from the plate itself --
    // the foreground halfway into the background, a ring that separates a card
    // without shouting. Not themeForeground(): that can ask for the accent.
    const auto BG = plateBackground();
    const auto FG = relLuma(BG) > 0.55F ? CHyprColor{0.08F, 0.08F, 0.08F, 1.F} : CHyprColor{1.F, 1.F, 1.F, 1.F};
    return mixColor(BG.modifyA(1.F), FG, 0.42F);
}

// The ring a grid tile wears when nothing is on it (the window's own inactive
// border), for the chrome that should sit as quietly as the tiles until the
// pointer or the keyboard is on it (user, 2026-09-27).
CHyprColor restingBorderColor() {
    static auto& INACTIVE = valueRef<::Config::IComplexConfigValue>("general:col.inactive_border");
    const auto*  G        = gradientPtr(INACTIVE);
    return (!G || G->m_colors.empty()) ? highlightColor() : G->m_colors[0];
}

CHyprColor highlightForeground() {
    const auto BG = highlightColor();

    // Rec. 709 relative luminance. Deciding this from the colour rather than
    // hardcoding either answer is what makes it survive a theme switch in
    // EITHER direction -- a light accent and a dark one both stay readable.
    if (const float LUMA = (0.2126F * BG.r) + (0.7152F * BG.g) + (0.0722F * BG.b); LUMA <= 0.55F)
        return CHyprColor{1.F, 1.F, 1.F, 1.F};

    // Not flat black: the accent's own dark end reads as the same material,
    // where black on a warm pink reads as a hole punched through it.
    return CHyprColor{BG.r * 0.18F, BG.g * 0.18F, BG.b * 0.18F, 1.F};
}

int themeRounding() {
    static auto& VAL = valueRef<Hyprlang::INT>("decoration:rounding");
    return std::max<int>(0, sc<int>(*VAL));
}

float themeRoundingPower() {
    static auto& VAL   = valueRef<Hyprlang::FLOAT>("decoration:rounding_power");
    const auto   POWER = sc<float>(*VAL);
    return std::clamp(POWER > 0.F ? POWER : 2.F, 1.F, 10.F);
}

// THE FONT (A14, P2-9). First answer wins:
//   plugin:hyprdrive:font            the plugin's own pin
//   misc:font_family                 when pinned -- Hyprland's unset default is
//                                    "Sans", which is nobody's choice
//   Omarchy                          `omarchy font set` writes
//                                    ~/.config/fontconfig/fonts.conf so the
//                                    "monospace" alias resolves to the chosen
//                                    family; its first <string> is that family
//                                    (unchanged from every earlier build)
//   anything else                    fontconfig's own answer for "monospace"
//                                    (Fonts::matchFamily), aliases, rejects
//                                    and all -- not a regex over a file
//
// Behind THEME_POLL_MS, and by reference. This runs inside OverviewRender::text()
// for every caller that does not pin a family -- which is most of them -- so it
// was a getenv, a stat() and two std::string copies per glyph-cache PROBE. The
// misc:font_family read is inside the gate with everything else: it only moves
// on a reload, and a reload invalidates this.
const std::string& themeFontFamily() {
    static std::string     resolved{"monospace"};   // what the last full check answered
    static std::string     parsed;                  // last successful fonts.conf parse
    static std::string     parsedPath;
    static time_t          parsedMtime = 0;
    static std::string     matched;                 // Fonts::matchFamily("monospace"), per generation
    static uint64_t        matchedGeneration = 0;
    static Time::steady_tp checkedAt{};
    static uint64_t        seenGeneration = 0;

    const auto NOW = Time::steadyNow();
    if (seenGeneration == g_themeGeneration && std::chrono::duration<float, std::milli>(NOW - checkedAt).count() < THEME_POLL_MS)
        return resolved;

    checkedAt      = NOW;
    seenGeneration = g_themeGeneration;

    if (auto own = pluginString("plugin:hyprdrive:font"); !own.empty()) {
        resolved = std::move(own);
        return resolved;
    }

    const auto PIN = getValue<std::string>("misc:font_family");
    if (!PIN.empty() && PIN != STRVAL_EMPTY && PIN != "Sans") {
        resolved = PIN;
        return resolved;
    }

    resolved = "monospace";

    if (!Hyprdrive::Integration::omarchy()) {
        if (matchedGeneration != g_themeGeneration) {
            matchedGeneration = g_themeGeneration;
            matched           = Hyprdrive::Fonts::matchFamily("monospace");
        }
        if (!matched.empty())
            resolved = matched;
        return resolved;
    }

    const char* const CFG  = std::getenv("XDG_CONFIG_HOME");
    const char* const HOME = std::getenv("HOME");
    const std::string PATH = (CFG && *CFG)  ? std::string{CFG} + "/fontconfig/fonts.conf" :
                             (HOME && *HOME) ? std::string{HOME} + "/.config/fontconfig/fonts.conf" :
                                               std::string{};
    if (PATH.empty())
        return resolved;

    struct stat st {};
    if (stat(PATH.c_str(), &st) != 0)
        return resolved;

    if (parsedPath == PATH && parsedMtime == st.st_mtime && !parsed.empty()) {
        resolved = parsed;
        return resolved;
    }

    parsedPath  = PATH;
    parsedMtime = st.st_mtime;
    parsed      = "monospace";

    std::ifstream in{PATH};
    if (!in) {
        resolved = parsed;
        return resolved;
    }

    static const std::regex RE{R"(<string>([^<]+)</string>)"};
    std::string             line;
    while (std::getline(in, line)) {
        std::smatch match;
        if (!std::regex_search(line, match, RE))
            continue;
        const auto NAME = match[1].str();
        if (NAME.empty() || NAME == "monospace")
            continue;
        parsed = NAME;
        break;
    }

    resolved = parsed;
    return resolved;
}

const std::string& glyphFontSetting() {
    static std::string value{"auto"};
    static uint64_t    seen = 0;
    if (seen != g_themeGeneration && g_pluginKeysRegistered) {
        seen  = g_themeGeneration;
        value = pluginString("plugin:hyprdrive:glyph_font", "auto");
        if (value.empty())
            value = "auto";
    }
    return value;
}

CHyprColor cpuPulseColor() {
    static auto& VAL = valueRef<Hyprlang::INT>("plugin:hyprdrive:dock:cpu_pulse_color");
    return colorFromArgb(sc<uint32_t>(*VAL));
}

// Behind THEME_POLL_MS like the family above: this runs for every text probe.
float themeTextScale() {
    static float           resolved = 1.F;
    static std::string     parsedPath;
    static time_t          parsedMtime = 0;
    static float           parsed      = 1.F;
    static Time::steady_tp checkedAt{};
    static uint64_t        seenGeneration = 0;

    const auto NOW = Time::steadyNow();
    if (seenGeneration == g_themeGeneration && std::chrono::duration<float, std::milli>(NOW - checkedAt).count() < THEME_POLL_MS)
        return resolved;
    checkedAt      = NOW;
    seenGeneration = g_themeGeneration;
    resolved       = 1.F;

    // default: Hyprdrive's own sizes. custom: the user's. system: Omarchy's, below.
    const auto MODE = getValue<std::string>("plugin:hyprdrive:general:text_size");
    if (MODE == "custom") {
        static auto& OWN = valueRef<Hyprlang::FLOAT>("plugin:hyprdrive:general:text_scale");
        resolved         = std::clamp(sc<float>(*OWN), Hyprdrive::TextScale::MIN_SCALE, Hyprdrive::TextScale::MAX_SCALE);
        return resolved;
    }
    if (MODE != "system")
        return resolved;

    const char* const CFG  = std::getenv("XDG_CONFIG_HOME");
    const char* const HOME = std::getenv("HOME");
    const std::string PATH = (CFG && *CFG)  ? std::string{CFG} + "/omarchy/shell.toml" :
                             (HOME && *HOME) ? std::string{HOME} + "/.config/omarchy/shell.toml" :
                                               std::string{};
    struct stat st {};
    if (PATH.empty() || stat(PATH.c_str(), &st) != 0)
        return resolved;
    if (parsedPath != PATH || parsedMtime != st.st_mtime) {
        parsedPath  = PATH;
        parsedMtime = st.st_mtime;
        parsed      = 1.F;
        // A settings file, not a place for a large read on the render thread.
        if (st.st_size > 0 && st.st_size <= 1024 * 1024) {
            if (std::ifstream in{PATH}; in) {
                std::string text(sc<size_t>(st.st_size), '\0');
                in.read(text.data(), st.st_size);
                text.resize(sc<size_t>(std::max<std::streamsize>(0, in.gcount())));
                parsed = Hyprdrive::TextScale::fromShellToml(text);
            }
        }
    }
    resolved = parsed;
    return resolved;
}

CHyprColor dockIndicatorColor() {
    static auto&   VAL  = valueRef<Hyprlang::INT>("plugin:hyprdrive:dock:indicator_color");
    const uint32_t ARGB = sc<uint32_t>(*VAL);
    if ((ARGB >> 24) == 0)
        return highlightColor();
    return colorFromArgb(ARGB);
}

// Overview chrome (dock, search, strip, results) follows unfocused window
// opacity. On Omarchy that is its default-opacity rule from
// ~/.config/hypr/windows.lua (`0.985 override 0.85 override`) on top of
// decoration:inactive_opacity. Off Omarchy there is no such rule (user,
// 2026-10-15: native "still tries to adopt omarchy's opacity settings instead
// of hyprland's"): Hyprland's own decoration:inactive_opacity, alone.
static float chromeWindowOpacity() {
    static constexpr float OMARCHY_DEFAULT_OPACITY = 0.85F;
    static auto& VAL      = valueRef<Hyprlang::FLOAT>("decoration:inactive_opacity");
    const float  INACTIVE = std::clamp(sc<float>(*VAL), 0.F, 1.F);
    if (!Hyprdrive::Integration::omarchy())
        return INACTIVE;
    return std::clamp(OMARCHY_DEFAULT_OPACITY * INACTIVE, 0.F, 1.F);
}

// THE TERMINAL'S GLASS (user, 2026-10-16: the dock, search, results and strip
// should be the same glass as Ghostty -- the blur was already Hyprland's, the
// tint over it was not: 0.85 over the theme's darkest shade, where the terminal
// is its background-opacity over its own background). Read from Ghostty's
// config: `config` / `config.ghostty` in its config dir, every `config-file`
// it includes (relative to the including file; a leading ? is optional), and a
// `theme` for the background when none is set outright. Later lines win. Only
// what Ghostty SETS is taken: no background-opacity line means no opinion.
//
// Re-read on the theme generation (a config reload), and otherwise at most
// every THEME_POLL_MS when a file it read changed -- a theme switch that only
// rewrites Ghostty's theme file (fedora's Serpantinum sync) is seen too.
struct SGhosttyGlass {
    std::optional<uint32_t> background; // 0xRRGGBB
    std::optional<float>    opacity;
};

static std::optional<uint32_t> ghosttyHex(std::string v) {
    if (!v.empty() && v.front() == '#')
        v.erase(0, 1);
    if (v.size() != 6 || !std::ranges::all_of(v, [](char c) { return std::isxdigit(sc<unsigned char>(c)) != 0; }))
        return std::nullopt;
    return sc<uint32_t>(std::stoul(v, nullptr, 16));
}

static std::string ghosttyUnquote(std::string v) {
    while (!v.empty() && std::isspace(sc<unsigned char>(v.back())))
        v.pop_back();
    if (v.size() >= 2 && (v.front() == '"' || v.front() == '\'') && v.back() == v.front())
        v = v.substr(1, v.size() - 2);
    return v;
}

static std::string ghosttyPath(std::string v, const std::filesystem::path& base) {
    if (!v.empty() && v.front() == '~')
        if (const char* home = std::getenv("HOME"); home && *home)
            v = std::string{home} + v.substr(1);
    std::filesystem::path p{v};
    return (p.is_absolute() ? p : base / p).string();
}

static void ghosttyRead(const std::string& path, int depth, SGhosttyGlass& out, std::optional<std::string>& theme, std::vector<std::pair<std::string, time_t>>& seen) {
    struct stat st {};
    if (depth > 6 || stat(path.c_str(), &st) != 0)
        return;
    seen.emplace_back(path, st.st_mtime);
    std::ifstream in{path};
    if (!in)
        return;
    std::vector<std::string> includes;
    std::string              line;
    while (std::getline(in, line)) {
        const auto EQ = line.find('=');
        if (EQ == std::string::npos)
            continue;
        std::string key = line.substr(0, EQ);
        std::erase_if(key, [](char c) { return std::isspace(sc<unsigned char>(c)) != 0; });
        if (key.empty() || key.front() == '#')
            continue;
        std::string val = line.substr(EQ + 1);
        val.erase(0, std::min(val.find_first_not_of(" \t"), val.size()));
        val = ghosttyUnquote(val);
        if (key == "background") {
            if (const auto HEX = ghosttyHex(val))
                out.background = HEX;
        } else if (key == "background-opacity") {
            try {
                out.opacity = std::clamp(std::stof(val), 0.F, 1.F);
            } catch (...) {}
        } else if (key == "theme")
            theme = val;
        else if (key == "config-file") {
            if (!val.empty() && val.front() == '?')
                val = ghosttyUnquote(val.substr(1));
            includes.push_back(ghosttyPath(val, std::filesystem::path{path}.parent_path()));
        }
    }
    // Ghostty loads a file's config-file includes after the file itself.
    for (const auto& INC : includes)
        ghosttyRead(INC, depth + 1, out, theme, seen);
}

static const SGhosttyGlass& ghosttyGlass() {
    static SGhosttyGlass                               cached;
    static std::vector<std::pair<std::string, time_t>> files; // what the last parse read, with mtimes
    static Time::steady_tp                             checkedAt{};
    static uint64_t                                    seenGeneration = 0;

    const auto NOW = Time::steadyNow();
    if (seenGeneration == g_themeGeneration && std::chrono::duration<float, std::milli>(NOW - checkedAt).count() < THEME_POLL_MS)
        return cached;
    const bool RELOADED = seenGeneration != g_themeGeneration;
    checkedAt           = NOW;
    seenGeneration      = g_themeGeneration;

    if (!RELOADED && !files.empty() && std::ranges::all_of(files, [](const auto& f) {
            struct stat st {};
            return stat(f.first.c_str(), &st) == 0 && st.st_mtime == f.second;
        }))
        return cached;

    const char* const CFG  = std::getenv("XDG_CONFIG_HOME");
    const char* const HOME = std::getenv("HOME");
    const std::filesystem::path DIR = (CFG && *CFG) ? std::filesystem::path{CFG} / "ghostty" :
                                      (HOME && *HOME) ? std::filesystem::path{HOME} / ".config/ghostty" :
                                                        std::filesystem::path{};
    cached = {};
    files.clear();
    if (DIR.empty())
        return cached;

    std::optional<std::string> theme;
    for (const char* NAME : {"config", "config.ghostty"})
        ghosttyRead((DIR / NAME).string(), 0, cached, theme, files);

    // A theme gives the background only where the config does not.
    if (!cached.background && theme && !theme->empty()) {
        // "light:A,dark:B": the dark one (the chrome is a dark-glass surface).
        std::string name = *theme;
        if (const auto DARK = name.find("dark:"); DARK != std::string::npos) {
            name = name.substr(DARK + 5);
            name = name.substr(0, name.find(','));
        }
        SGhosttyGlass                                      themed;
        std::optional<std::string>                         ignored;
        const std::filesystem::path                        P{name};
        for (const auto& CAND : P.is_absolute() ? std::vector<std::string>{name} :
                                                  std::vector<std::string>{(DIR / "themes" / name).string(), "/usr/share/ghostty/themes/" + name}) {
            if (std::filesystem::exists(CAND)) {
                ghosttyRead(CAND, 0, themed, ignored, files);
                break;
            }
        }
        cached.background = themed.background;
    }
    return cached;
}

CHyprColor dockBackgroundColor() {
    static auto& OPACITYVAL = valueRef<Hyprlang::FLOAT>("plugin:hyprdrive:dock:background_opacity");
    static auto& COLORVAL   = valueRef<Hyprlang::INT>("plugin:hyprdrive:dock:background_color");
    static auto& FALLBACK   = valueRef<Hyprlang::INT>("misc:background_color");

    const auto& GLASS = ghosttyGlass();

    float OPACITY = sc<float>(*OPACITYVAL);
    if (OPACITY >= 0.F)
        OPACITY = std::clamp(OPACITY, 0.F, 1.F);
    else if (GLASS.opacity)
        OPACITY = *GLASS.opacity; // the terminal's glass
    else
        OPACITY = chromeWindowOpacity();

    const uint32_t ARGB = sc<uint32_t>(*COLORVAL);
    if ((ARGB >> 24) != 0)
        return colorFromArgb(ARGB).modifyA(OPACITY);
    if (const auto BG = THEME_KEY("background"))
        return BG->modifyA(OPACITY);
    if (GLASS.background)
        return colorFromArgb(*GLASS.background).modifyA(OPACITY); // the terminal's background
    if (const auto& P = palette(); P.valid && P.hasBg)
        return colorFromArgb(P.background).modifyA(OPACITY);
    return colorFromArgb(sc<uint32_t>(*FALLBACK)).modifyA(OPACITY);
}

int dockCornerRadius() {
    static auto& VAL = valueRef<Hyprlang::INT>("plugin:hyprdrive:dock:corner_radius");
    return std::max<int>(0, sc<int>(*VAL));
}

}
