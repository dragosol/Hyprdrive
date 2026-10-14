// Host test for Fonts (native port A14/A15), against fontconfig configurations
// it writes itself. fontconfig initialises once per process, so each scenario
// runs in a child (this binary re-executed with a mode and FONTCONFIG_FILE):
//
//   empty      a config with no font directories at all: no icon font, no
//              codepoint "covered", matchFamily answers without crashing.
//   ligature   ONLY a host font that maps U+F002 but is no icon font (Ubuntu,
//              Liberation... -- the "fl" ligature in Apple's legacy PUA): it
//              must NOT be taken for an icon font. Skipped when the host has
//              no such font.
//   host       the machine's real fonts: whatever is chosen is installed,
//              covers at least MIN_COVERAGE of the glyphs and the anchor, and
//              "builtin" chooses nothing.
#include "../Fonts.hpp"
#include "../Glyphs.hpp"

#include <fontconfig/fontconfig.h>

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <sys/wait.h>
#include <unistd.h>

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

static void writeConf(const std::filesystem::path& conf, const std::filesystem::path& fontDir, const std::filesystem::path& cache) {
    std::ofstream out{conf};
    out << "<?xml version=\"1.0\"?>\n<!DOCTYPE fontconfig SYSTEM \"urn:fontconfig:fonts.dtd\">\n<fontconfig>\n";
    if (!fontDir.empty())
        out << "  <dir>" << fontDir.string() << "</dir>\n";
    out << "  <cachedir>" << cache.string() << "</cachedir>\n</fontconfig>\n";
}

// A host font file that has U+F002 but not the anchor U+F07C, or "".
static std::string ligatureFontFile() {
    if (!FcInit())
        return {};
    FcPattern* pat  = FcPatternCreate();
    FcCharSet* need = FcCharSetCreate();
    FcCharSetAddChar(need, 0xF002);
    FcPatternAddCharSet(pat, FC_CHARSET, need);
    FcObjectSet* os = FcObjectSetBuild(FC_FILE, FC_CHARSET, nullptr);
    FcFontSet*   fs = FcFontList(nullptr, pat, os);
    std::string  out;
    for (int i = 0; fs && i < fs->nfont && out.empty(); ++i) {
        FcChar8*   file = nullptr;
        FcCharSet* cs   = nullptr;
        if (FcPatternGetString(fs->fonts[i], FC_FILE, 0, &file) == FcResultMatch && FcPatternGetCharSet(fs->fonts[i], FC_CHARSET, 0, &cs) == FcResultMatch &&
            !FcCharSetHasChar(cs, 0xF07C))
            out = reinterpret_cast<const char*>(file);
    }
    if (fs)
        FcFontSetDestroy(fs);
    FcObjectSetDestroy(os);
    FcCharSetDestroy(need);
    FcPatternDestroy(pat);
    return out;
}

static int child(const char* self, const char* mode, const std::filesystem::path& conf) {
    const pid_t PID = fork();
    if (PID == 0) {
        setenv("FONTCONFIG_FILE", conf.c_str(), 1);
        execl(self, self, mode, nullptr);
        _exit(127);
    }
    int status = 0;
    waitpid(PID, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 99;
}

static int runMode(const std::string& mode) {
    if (mode == "empty") {
        CHECK(Fonts::iconFamily("auto").empty());
        CHECK(Fonts::iconCoverage("auto") == 0);
        for (const char32_t CP : Glyphs::named())
            CHECK(!Fonts::iconCovers("auto", CP));
        CHECK(Fonts::iconFamily("Iosevka Nerd Font").empty()); // named but absent: detect -> none
        CHECK(!Fonts::installed("Iosevka Nerd Font"));
        (void)Fonts::matchFamily("monospace"); // no fonts: must simply not crash
        CHECK(Fonts::matchFamily("").empty());
    } else if (mode == "ligature") {
        CHECK(Fonts::iconFamily("auto").empty());
        CHECK(!Fonts::iconCovers("auto", 0xF002)); // the font HAS it -- as "fl"
    } else if (mode == "host") {
        const auto& FAM = Fonts::iconFamily("auto");
        if (!FAM.empty()) {
            CHECK(Fonts::installed(FAM));
            CHECK(Fonts::iconCovers("auto", 0xF07C));
            CHECK(static_cast<double>(Fonts::iconCoverage("auto")) >= Fonts::MIN_COVERAGE * static_cast<double>(Glyphs::named().size()));
            // Naming the chosen family explicitly chooses it.
            CHECK(Fonts::iconFamily(FAM) == FAM);
        }
        CHECK(Fonts::iconFamily("builtin").empty() && !Fonts::iconCovers("builtin", 0xF07C));
        CHECK(!Fonts::matchFamily("monospace").empty());
        Fonts::reset();
        CHECK(Fonts::iconFamily("auto") == FAM); // deterministic across a reset
        std::printf("host icon font: \"%s\" (%zu/%zu), monospace = \"%s\"\n", FAM.c_str(), Fonts::iconCoverage("auto"), Glyphs::named().size(),
                    Fonts::matchFamily("monospace").c_str());
    } else
        return 2;
    return g_failed ? 1 : 0;
}

int main(int argc, char** argv) {
    if (argc > 1)
        return runMode(argv[1]);

    const auto TMP = std::filesystem::temp_directory_path() / ("fonts_test." + std::to_string(getpid()));
    std::filesystem::create_directories(TMP / "empty" / "fonts");
    std::filesystem::create_directories(TMP / "lig" / "fonts");
    std::filesystem::create_directories(TMP / "cache");

    writeConf(TMP / "empty" / "fonts.conf", TMP / "empty" / "fonts", TMP / "cache");
    CHECK(child(argv[0], "empty", TMP / "empty" / "fonts.conf") == 0);

    int        scenarios = 1;
    const auto LIG       = ligatureFontFile();
    if (!LIG.empty()) {
        std::error_code ec;
        std::filesystem::create_symlink(LIG, TMP / "lig" / "fonts" / std::filesystem::path{LIG}.filename(), ec);
        writeConf(TMP / "lig" / "fonts.conf", TMP / "lig" / "fonts", TMP / "cache");
        CHECK(child(argv[0], "ligature", TMP / "lig" / "fonts.conf") == 0);
        ++scenarios;
    } else
        std::printf("no ligature-PUA font on this host; that scenario is skipped\n");

    // The host's own configuration: FONTCONFIG_FILE as the caller has it.
    if (const char* F = std::getenv("FONTCONFIG_FILE"); F && *F)
        CHECK(child(argv[0], "host", F) == 0);
    else {
        const pid_t PID = fork();
        if (PID == 0) {
            execl(argv[0], argv[0], "host", nullptr);
            _exit(127);
        }
        int status = 0;
        waitpid(PID, &status, 0);
        CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    }
    ++scenarios;

    std::filesystem::remove_all(TMP);
    std::printf("fonts_test: %d scenarios (ligature font: %s), %d checks, %d failed\n", scenarios, LIG.empty() ? "none" : LIG.c_str(), g_checks, g_failed);
    return g_failed ? 1 : 0;
}
