#pragma once

#include <hyprland/src/plugins/PluginAPI.hpp>

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <string>

inline HANDLE SCROLLOVERVIEW_HANDLE = nullptr;

// The search query, the keyboard selection, the result drag and the layout the
// search step publishes all live in SearchSession.hpp -- one grouped object with
// one reset, instead of the six loose globals that used to sit here.

// STANDING UX RULE (RICE_PROGRESS.md): the rice has exactly TWO motion curves,
// mirrored in hyprland/general.lua as `appleDecel`/`appleAccel` and in the
// quickshell Appearance.qml. Registered once with Hyprland's animation manager
// in CScrollOverview's constructor, so anything hand-rolled can evaluate the
// SAME curve object instead of approximating it with a polynomial.
inline constexpr const char* HOUSE_DECEL_BEZIER = "hyprdriveOpen";
inline constexpr const char* HOUSE_ACCEL_BEZIER = "hyprdriveClose";

// The house curve at t in [0,1]. Entrances decelerate, exits accelerate.
// Falls back to a cubic of the right direction if called before the curves are
// registered -- a wrong-but-sane shape beats linear.
float houseEase(bool decel, float t);

// OVERVIEW_CPP_SPEC §13.12 X52. Keystroke-to-paint profiler for the search
// path. Gated on $HYPRDRIVE_PROFILE so it is one predictable branch when
// off ($SCROLLOVERVIEW_PROFILE also works, for one release); the standing rule is that a performance claim is closed by a measurement
// of the moment complained about, and this is the instrument for that moment.
namespace Prof {
    inline bool enabled() {
        static const bool ON = std::getenv("HYPRDRIVE_PROFILE") != nullptr || std::getenv("SCROLLOVERVIEW_PROFILE") != nullptr;
        return ON;
    }

    using clock = std::chrono::steady_clock;

    inline uint64_t    matchNs = 0, matchCalls = 0;   // overviewSearchMatches
    inline uint64_t    appNs   = 0, appCalls   = 0;   // AppSearch::search
    inline uint64_t    rowsNs  = 0, rowsCalls  = 0;   // overviewSearchRows
    inline uint64_t    scanNs  = 0, scanCalls  = 0;   // AppSearch corpus scan (.desktop walk)
    inline uint64_t    srchNs  = 0, srchCalls  = 0;   // renderSearch (layout + text + icons)
    inline uint64_t    txtNs   = 0, txtCold    = 0;   // cold renderText (pango layout + raster + upload)
    inline uint64_t    icoResolveNs = 0, icoDecodeNs = 0, icoUploadNs = 0, icoCold = 0;
    inline uint64_t    frameNs = 0, frameCalls = 0;   // the whole overview render pass
    inline uint64_t    bgNs    = 0, bgCalls    = 0;   // renderWorkspaceBackground walk
    inline uint64_t    liveNs  = 0, liveCalls  = 0;   // renderWorkspaceLive walk (the tiles)
    inline uint64_t    stripNs = 0, stripCalls = 0;   // renderStrip
    inline clock::time_point keyAt{};
    inline bool        pending = false;
    inline uint64_t    frames  = 0;                   // frames since the keystroke

    inline void reset() { txtNs = txtCold = scanNs = scanCalls = matchNs = matchCalls = appNs = appCalls = rowsNs = rowsCalls = srchNs = srchCalls = frameNs = frameCalls = frames = 0; icoResolveNs = icoDecodeNs = icoUploadNs = icoCold = 0; bgNs = bgCalls = liveNs = liveCalls = stripNs = stripCalls = 0; }

    // Accumulates into a counter pair. Reads the clock only while profiling.
    struct Timer {
        uint64_t*        ns    = nullptr;
        uint64_t*        calls = nullptr;
        clock::time_point t0{};

        Timer(uint64_t& nsSink, uint64_t& callSink) {
            if (!enabled())
                return;
            ns = &nsSink; calls = &callSink; t0 = clock::now();
        }
        ~Timer() {
            if (!ns)
                return;
            *ns += std::chrono::duration_cast<std::chrono::nanoseconds>(clock::now() - t0).count();
            ++*calls;
        }
    };
}

bool ensureScrollOverviewHooks();
void disableScrollOverviewHooks();
