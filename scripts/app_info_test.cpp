// AppInfo.cpp's Get Info script against stand-in package managers: each one
// that is installed is asked in turn, so a box that carries more than one
// (fedora with dpkg installed, E11) still finds the owner. The stand-ins are
// shell scripts on a PATH of their own; the real tools on the host never run.
#include "../AppInfo.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>
#include <unistd.h>

namespace fs = std::filesystem;

static int g_fail = 0;

static void tool(const fs::path& bin, const std::string& name, const std::string& body) {
    const auto P = bin / name;
    std::ofstream(P) << "#!/bin/sh\n" << body << "\n";
    fs::permissions(P, fs::perms::owner_all);
}

static std::string field(const AppInfo::SInfo& info, const std::string& key) {
    for (const auto& [K, V] : info.fields)
        if (K == key)
            return V;
    return "";
}

static AppInfo::SInfo ask(const std::string& path) {
    for (int i = 0; i < 500; ++i) {
        const auto INFO = AppInfo::lookup(path, "x");
        if (INFO.ready)
            return INFO;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return {};
}

static void expect(const char* name, const std::string& path, const std::string& source, const std::string& package, const std::string& version) {
    const auto INFO = ask(path);
    const bool OK   = INFO.ready && field(INFO, "Source") == source && field(INFO, "Package") == package && field(INFO, "Version") == version;
    std::printf("%s %s: Source=\"%s\" Package=\"%s\" Version=\"%s\"\n", OK ? "ok  " : "FAIL", name, field(INFO, "Source").c_str(), field(INFO, "Package").c_str(),
                field(INFO, "Version").c_str());
    if (!OK)
        ++g_fail;
}

int main() {
    char       tmpl[] = "/tmp/app_info_test.XXXXXX";
    const fs::path ROOT = mkdtemp(tmpl);

    // The script's own helpers, from the host; no package manager among them.
    const auto BASE = ROOT / "base";
    fs::create_directories(BASE);
    for (const char* T : {"sh", "head", "cut", "sed", "grep", "awk", "basename"}) {
        for (const char* DIR : {"/usr/bin/", "/bin/"}) {
            if (fs::exists(std::string(DIR) + T)) {
                fs::create_symlink(std::string(DIR) + T, BASE / T);
                break;
            }
        }
    }

    const auto RPM_OWNS  = "case \"$*\" in *--qf*) printf 'kitty\\t0.47.1-1.fc44\\n'; exit 0;; esac; exit 0";
    const auto RPM_MISS  = "echo \"file $3 is not owned by any package\"; exit 1"; // rpm says so on STDOUT
    const auto DPKG_MISS = "echo \"dpkg-query: no path found matching pattern $2\" >&2; exit 1";
    const auto DPKG_OWNS = "echo \"kitty: $2\"; exit 0";
    const auto DPKGQ     = "printf '0.26.1-1'";
    const auto PAC_MISS  = "echo \"error: No package owns $2\" >&2; exit 1";

    struct SCase {
        const char*                                      name;
        std::vector<std::pair<std::string, std::string>> tools;
        const char*                                      source;
        const char*                                      package;
        const char*                                      version;
    };
    const std::vector<SCase> CASES = {
        {"fedora with dpkg installed (E11)", {{"dpkg", DPKG_MISS}, {"rpm", RPM_OWNS}}, "rpm", "kitty", "0.47.1-1.fc44"},
        {"pacman present, rpm owns", {{"pacman", PAC_MISS}, {"rpm", RPM_OWNS}}, "rpm", "kitty", "0.47.1-1.fc44"},
        {"debian with rpm installed", {{"rpm", RPM_MISS}, {"dpkg", DPKG_OWNS}, {"dpkg-query", DPKGQ}}, "dpkg", "kitty", "0.26.1-1"},
        {"rpm only, owner", {{"rpm", RPM_OWNS}}, "rpm", "kitty", "0.47.1-1.fc44"},
        {"rpm only, not owned", {{"rpm", RPM_MISS}}, "Local (not from a package)", "", ""},
        {"every manager misses", {{"pacman", PAC_MISS}, {"rpm", RPM_MISS}, {"dpkg", DPKG_MISS}}, "Local (not from a package)", "", ""},
        {"no package manager", {}, "Local (not from a package)", "", ""},
    };

    int n = 0;
    for (const auto& C : CASES) {
        const auto BIN = ROOT / ("bin" + std::to_string(n));
        fs::create_directories(BIN);
        for (const auto& [NAME, BODY] : C.tools)
            tool(BIN, NAME, BODY);
        setenv("PATH", (BIN.string() + ":" + BASE.string()).c_str(), 1);
        // A path per case: answers are cached by the .desktop path.
        expect(C.name, "/usr/share/applications/case" + std::to_string(n++) + ".desktop", C.source, C.package, C.version);
    }

    AppInfo::shutdown();
    fs::remove_all(ROOT);
    std::printf("%d/%zu cases\n", n - g_fail, CASES.size());
    return g_fail ? 1 : 0;
}
