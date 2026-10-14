// Host test for IntegrationRule.hpp -- the "is this Omarchy?" rule -- and for
// its shell twin, scripts/hyprdrive-integration, which `make install` and
// hdpanel use when no compositor is there to ask. Two implementations of one
// rule is a drift waiting to happen, so the second half of this test runs the
// shell script (offline) over EVERY combination of inputs and requires it to
// print exactly what decide() returns: name, source and reason.
#include "../IntegrationRule.hpp"

#include <array>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

using namespace ScrollOverview::Integration;

static int g_checks = 0, g_failed = 0;
#define CHECK(c)                                                                                                                                                                   \
    do {                                                                                                                                                                           \
        ++g_checks;                                                                                                                                                                \
        if (!(c)) {                                                                                                                                                                \
            ++g_failed;                                                                                                                                                            \
            std::printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                                                                                                               \
        }                                                                                                                                                                          \
    } while (0)

static SProbe P(bool off, std::string env, std::string cfg, bool path, bool state, bool installed = false, bool pathEnv = false) {
    return SProbe{.noOmarchyEnv     = off,
                  .envValue         = std::move(env),
                  .configValue      = std::move(cfg),
                  .omarchyOnPath    = path,
                  .omarchyInstalled = installed,
                  .omarchyPathEnv   = pathEnv,
                  .omarchyState     = state};
}

static std::string sq(const std::string& s) { // single-quote for sh
    std::string out = "'";
    for (const char C : s)
        out += C == '\'' ? std::string{"'\\''"} : std::string(1, C);
    return out + "'";
}

int main() {
    static_assert(parseValue("auto") == 0 && parseValue("omarchy") == 1 && parseValue("none") == 2);
    static_assert(parseValue("") == -1 && parseValue("Omarchy") == -1 && parseValue("yes") == -1);

    // ---- the rule ---------------------------------------------------------
    // auto needs BOTH halves.
    CHECK(decide(P(false, "", "", true, true)).desktop == EDesktop::Omarchy);
    CHECK(decide(P(false, "", "", true, false)).desktop == EDesktop::None);  // package, never run
    CHECK(decide(P(false, "", "", false, true)).desktop == EDesktop::None);  // hyprtest on fedora
    CHECK(decide(P(false, "", "", false, false)).desktop == EDesktop::None);
    CHECK(decide(P(false, "", "auto", true, true)).source == ESource::Auto);

    // The install half has three signals: PATH, ~/.local/share/omarchy/bin,
    // $OMARCHY_PATH. Any one of them, with the state dir, is Omarchy -- a
    // Hyprland started before the PATH carries Omarchy's bin dir (uwsm, a
    // display manager, a nested test) still finds it. None of them alone is.
    CHECK(decide(P(false, "", "", false, true, true, false)).desktop == EDesktop::Omarchy);
    CHECK(decide(P(false, "", "", false, true, false, true)).desktop == EDesktop::Omarchy);
    CHECK(decide(P(false, "", "", false, false, true, true)).desktop == EDesktop::None);
    CHECK(decide(P(false, "", "", false, true, true, false)).reason == "omarchy in ~/.local/share/omarchy/bin and omarchy state dir present");
    CHECK(decide(P(false, "", "", false, true, false, true)).reason == "OMARCHY_PATH set and omarchy state dir present");
    CHECK(decide(P(false, "", "", true, true, true, true)).reason == "omarchy on PATH and omarchy state dir present"); // first signal names it
    CHECK(decide(P(false, "none", "", true, true, true, true)).desktop == EDesktop::None);                             // overrides still win

    // The force-off beats everything, including an explicit omarchy.
    CHECK(decide(P(true, "omarchy", "omarchy", true, true)).desktop == EDesktop::None);
    CHECK(decide(P(true, "omarchy", "omarchy", true, true)).source == ESource::ForceOff);
    // Only "1" is a force-off.
    CHECK(decide(P(false, "", "", true, true)).desktop == EDesktop::Omarchy);

    // Env beats config; config beats auto; auto in either falls through.
    CHECK(decide(P(false, "none", "omarchy", true, true)).desktop == EDesktop::None);
    CHECK(decide(P(false, "none", "omarchy", true, true)).source == ESource::Env);
    CHECK(decide(P(false, "omarchy", "none", false, false)).desktop == EDesktop::Omarchy);
    CHECK(decide(P(false, "auto", "none", true, true)).source == ESource::Config);
    CHECK(decide(P(false, "auto", "none", true, true)).desktop == EDesktop::None);
    CHECK(decide(P(false, "", "omarchy", false, false)).desktop == EDesktop::Omarchy);
    CHECK(decide(P(false, "auto", "auto", true, true)).desktop == EDesktop::Omarchy);

    // A typo is auto, and the reason names it.
    {
        const auto D = decide(P(false, "Omarchy", "", true, true));
        CHECK(D.desktop == EDesktop::Omarchy && D.source == ESource::Auto);
        CHECK(D.reason.find("HYPRDRIVE_INTEGRATION=\"Omarchy\"") != std::string::npos);
    }

    // ---- the shell twin ---------------------------------------------------
    const auto TMP = std::filesystem::temp_directory_path() / ("hd-integration-" + std::to_string(getpid()));
    std::filesystem::remove_all(TMP);
    std::filesystem::create_directories(TMP / "bin");
    std::filesystem::create_directories(TMP / "empty");
    std::filesystem::create_directories(TMP / "state/omarchy/current");
    std::filesystem::create_directories(TMP / "nostate");
    std::filesystem::create_directories(TMP / "home/.local/share/omarchy/bin");
    if (FILE* F = std::fopen((TMP / "home/.local/share/omarchy/bin/omarchy").c_str(), "w")) {
        std::fputs("#!/bin/sh\n", F);
        std::fclose(F);
    }
    chmod((TMP / "home/.local/share/omarchy/bin/omarchy").c_str(), 0755);
    if (FILE* F = std::fopen((TMP / "bin/omarchy").c_str(), "w")) {
        std::fputs("#!/bin/sh\n", F);
        std::fclose(F);
    }
    chmod((TMP / "bin/omarchy").c_str(), 0755);

    const std::array<std::string, 5> VALUES{"", "auto", "omarchy", "none", "Bogus"};
    int                              shellCases = 0;
    for (const bool OFF : {false, true})
        for (const auto& ENV : VALUES)
            for (const auto& CFG : VALUES)
                for (const bool PATH_ : {false, true})
                    for (const bool STATE : {false, true})
                        for (const bool INST : {false, true})
                            for (const bool OPENV : {false, true}) {
                        const auto  WANT = decide(P(OFF, ENV, CFG, PATH_, STATE, INST, OPENV));
                        // env -i: nothing of the test runner's own environment
                        // (a real HYPRDRIVE_* or an Omarchy PATH) leaks in. The
                        // offline path uses only shell builtins, so a PATH of
                        // just the fake bin dir (or an empty one) is enough.
                        std::string cmd = "env -i HOME=" + (INST ? sq((TMP / "home").string()) : std::string{"/nonexistent"}) +
                            " PATH=" + sq((TMP / (PATH_ ? "bin" : "empty")).string()) + " XDG_STATE_HOME=" + sq((TMP / (STATE ? "state" : "nostate")).string());
                        if (OPENV)
                            cmd += " OMARCHY_PATH=" + sq((TMP / "home/.local/share/omarchy").string());
                        if (OFF)
                            cmd += " HYPRDRIVE_NO_OMARCHY=1";
                        if (!ENV.empty())
                            cmd += " HYPRDRIVE_INTEGRATION=" + sq(ENV);
                        cmd += " /bin/sh scripts/hyprdrive-integration --offline --why --config " + sq(CFG) + " 2>&1";

                        std::string out;
                        if (FILE* PIPE = popen(cmd.c_str(), "r")) {
                            char buf[512];
                            while (std::fgets(buf, sizeof buf, PIPE))
                                out += buf;
                            pclose(PIPE);
                        }
                        const std::string EXPECT = std::string{name(WANT.desktop)} + "\nsource: " + std::string{name(WANT.source)} + "\nreason: " + WANT.reason + "\n";
                        ++shellCases;
                        CHECK(out == EXPECT);
                        if (out != EXPECT)
                            std::printf("  case off=%d env=%s cfg=%s path=%d state=%d inst=%d openv=%d\n  want:\n%s  got:\n%s", OFF, ENV.c_str(), CFG.c_str(), PATH_, STATE,
                                        INST, OPENV, EXPECT.c_str(), out.c_str());
                            }

    // -q speaks through the exit status only.
    {
        const std::string BASE = "env -i HOME=/nonexistent PATH=" + sq((TMP / "bin").string()) + " XDG_STATE_HOME=" + sq((TMP / "state").string()) +
            " /bin/sh scripts/hyprdrive-integration --offline -q";
        CHECK(WEXITSTATUS(std::system(BASE.c_str())) == 0);
        CHECK(WEXITSTATUS(std::system(("HYPRDRIVE_NO_OMARCHY=1 " + BASE).c_str())) == 0); // env -i drops it: still omarchy
        const std::string OFFQ = "env -i HOME=/nonexistent HYPRDRIVE_NO_OMARCHY=1 PATH=" + sq((TMP / "bin").string()) + " XDG_STATE_HOME=" +
            sq((TMP / "state").string()) + " /bin/sh scripts/hyprdrive-integration --offline -q";
        CHECK(WEXITSTATUS(std::system(OFFQ.c_str())) == 1);
    }

    std::filesystem::remove_all(TMP);
    std::printf("%d checks, %d failed (%d shell parity cases)\n", g_checks, g_failed, shellCases);
    return g_failed ? 1 : 0;
}
