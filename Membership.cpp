#include "globals.hpp"

#include <cstdarg>
#include <filesystem>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unordered_map>

// P6i1, STEP ONE: the generation counter and a SHADOW of the cache it is meant
// to key, running beside the live gate and agreeing with it or saying so.
//
// The plan is a membership snapshot: `shouldShowOverviewWindow` is consulted
// from about sixty places -- render, hit-test, drag, the grid, the strip, the
// frame pacer -- and every one of them recomputes it. One snapshot, invalidated
// by a generation that every mutator bumps, is both cheaper and the only way
// those callers cannot disagree inside a frame.
//
// The danger is entirely in the bump set. A mutator nobody thought of means a
// stale answer: a window that renders when it should not, or worse, one that
// stops rendering and cannot be got back -- which is the exact shape of Z20 and
// of the Y9 minimized-window bug, both of which cost rounds. So no reader is
// switched over here. Instead every call computes the live answer AND what a
// generation-keyed cache would have returned, and any disagreement is written
// down with the window that caused it and the generation it happened in.
//
// A run with divergence 0 and a non-trivial HIT count is the evidence the
// cutover needs. A run with divergence 0 and hits 0 proves nothing at all --
// that is a generation churning faster than it is read -- which is why the
// report prints both and why the hit rate is the first number to look at.
//
// Remove this file at cutover; it has no other purpose.

namespace Membership {
    namespace {
        uint64_t g_generation = 1;

        struct SEntry {
            uint64_t generation = 0;
            bool     member     = false;
        };

        std::unordered_map<const void*, SEntry> g_cache;

        uint64_t g_checks = 0;    // calls to the gate
        uint64_t g_hits   = 0;    // ...answered by an entry of the current generation
        uint64_t g_fills  = 0;    // ...that had to fill or refresh one
        uint64_t g_bumps  = 0;
        uint64_t g_diverged = 0;

        // The last few reasons, so a divergence can be read against what had
        // just happened rather than against the whole log.
        std::string g_lastBump = "(none)";

        const char* logPath() {
            static std::string PATH = [] {
                const char* HOME = std::getenv("HOME");
                std::string dir  = std::string(HOME ? HOME : "/tmp") + "/.local/state/hyprdrive";
                // NOT system("mkdir -p"): forking a shell out of a running
                // compositor to make one directory is the sort of thing that
                // works until the day it does not.
                std::error_code ec;
                std::filesystem::create_directories(dir, ec);
                return dir + "/membership-shadow.log";
            }();
            return PATH.c_str();
        }

        void say(const char* fmt, ...) {
            FILE* f = std::fopen(logPath(), "a");
            if (!f)
                return;
            va_list ap;
            va_start(ap, fmt);
            std::vfprintf(f, fmt, ap);
            va_end(ap);
            std::fclose(f);
        }
    }

    void bump(const char* why) {
        ++g_generation;
        ++g_bumps;
        g_lastBump = why ? why : "?";
    }

    void report(const char* when) {
        say("REPORT %-18s generation %llu  checks %llu  hits %llu (%.1f%%)  fills %llu  bumps %llu  DIVERGED %llu  cache %zu  last bump %s\n", when,
            (unsigned long long)g_generation, (unsigned long long)g_checks, (unsigned long long)g_hits,
            g_checks ? 100.0 * (double)g_hits / (double)g_checks : 0.0, (unsigned long long)g_fills, (unsigned long long)g_bumps,
            (unsigned long long)g_diverged, g_cache.size(), g_lastBump.c_str());
    }

    // True when a generation-keyed cache would have agreed with the live gate
    // (or had nothing to say and was filled). False is a divergence, and the
    // caller has the window to name it with.
    bool observe(const void* key, bool live) {
        ++g_checks;

        // Keep it bounded the same way the grid maps are: this is a shadow, not
        // a leak. Address reuse after an erase is exactly one of the things the
        // divergence count is here to catch, so nothing clever is done about it.
        if (g_cache.size() > 512)
            g_cache.clear();

        auto& ENTRY = g_cache[key];
        if (ENTRY.generation == g_generation) {
            ++g_hits;
            if (ENTRY.member == live)
                return true;
            ++g_diverged;
            ENTRY.member = live; // report each divergence once, not once per call
            return false;
        }

        ++g_fills;
        ENTRY = SEntry{g_generation, live};

        // Liveness. A shadow that stopped running would otherwise read as a
        // clean run.
        if (g_checks == 1)
            report("first check");
        else if (g_checks % 20000 == 0)
            report("periodic");

        return true;
    }

    void divergence(const std::string& cls, const std::string& title, bool live) {
        say("DIVERGE generation %llu  live=%s  cached=%s  class=%s  title=%s  last bump=%s\n", (unsigned long long)g_generation, live ? "in" : "out",
            live ? "out" : "in", cls.c_str(), title.c_str(), g_lastBump.c_str());
        if (g_diverged <= 3 || g_diverged % 100 == 0)
            report("at divergence");
    }
}
