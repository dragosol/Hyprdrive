// Host test for DebugPaths.hpp: the debug logs go to $XDG_RUNTIME_DIR when it
// is a usable directory, /tmp otherwise.
#include "../DebugPaths.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
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
    char       tmpl[] = "/tmp/debug_paths_test.XXXXXX";
    const auto DIR    = std::string{::mkdtemp(tmpl)};
    CHECK(!DIR.empty());

    CHECK(DebugPaths::dirFor(DIR.c_str()) == DIR);
    CHECK(DebugPaths::dirFor((DIR + "/").c_str()) == DIR); // a trailing slash does not double up
    CHECK(DebugPaths::dirFor(nullptr) == "/tmp");
    CHECK(DebugPaths::dirFor("") == "/tmp");
    CHECK(DebugPaths::dirFor("relative/dir") == "/tmp");
    CHECK(DebugPaths::dirFor((DIR + "/missing").c_str()) == "/tmp");
    {
        const auto FILE = DIR + "/a-file";
        std::fclose(std::fopen(FILE.c_str(), "w"));
        CHECK(DebugPaths::dirFor(FILE.c_str()) == "/tmp"); // a file is not a directory
    }
    CHECK(DebugPaths::dirFor("/") == "/");

    // The cached one follows the environment it was first asked under.
    ::setenv("XDG_RUNTIME_DIR", DIR.c_str(), 1);
    CHECK(DebugPaths::path("hyprdrive-compat.log") == DIR + "/hyprdrive-compat.log");

    std::filesystem::remove_all(DIR);
    std::printf("debug_paths_test: %d checks, %d failed\n", g_checks, g_failed);
    return g_failed ? 1 : 0;
}
