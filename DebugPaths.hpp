#pragma once

// WHERE THE DEBUG LOGS AND THEIR SWITCH FILES LIVE: $XDG_RUNTIME_DIR, else /tmp.
//
// They were fixed /tmp paths, one per machine, shared by every Hyprland on it.
// Two headless test instances (hl.sh runs one per agent) wrote the same
// /tmp/hyprdrive-compat.log, and one instance's load TRUNCATED it under the
// other's gate; a `touch /tmp/hyprdrive-openprof.on` meant for one session
// switched on the profiler in all of them. A session's runtime directory is
// its own (per user, and per instance in the harness), and it is where the
// compositor's sockets already live. No XDG_RUNTIME_DIR (or not a directory):
// /tmp, as before. docs/DEBUG.md lists every name.
//
// Header-only, no Hyprland headers: scripts/debug_paths_test.cpp checks it.

#include <cstdlib>
#include <string>
#include <string_view>
#include <sys/stat.h>

namespace ScrollOverview::DebugPaths {

    // The directory for a given XDG_RUNTIME_DIR value (null = unset). Only an
    // absolute path to an existing directory counts; anything else is /tmp.
    inline std::string dirFor(const char* runtimeDir) {
        struct stat st{};
        if (runtimeDir && runtimeDir[0] == '/' && ::stat(runtimeDir, &st) == 0 && S_ISDIR(st.st_mode)) {
            std::string dir{runtimeDir};
            while (dir.size() > 1 && dir.back() == '/')
                dir.pop_back();
            return dir;
        }
        return "/tmp";
    }

    // Read once: the compositor's environment does not change under it.
    inline const std::string& dir() {
        static const std::string DIR = dirFor(std::getenv("XDG_RUNTIME_DIR"));
        return DIR;
    }

    // e.g. path("hyprdrive-compat.log") -> /run/user/1000/hyprdrive-compat.log
    inline std::string path(std::string_view name) {
        return dir() + "/" + std::string{name};
    }
}
