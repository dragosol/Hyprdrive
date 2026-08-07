#include "IOverview.hpp"

#include <algorithm>

#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/output/Monitor.hpp>

static std::vector<SP<IOverview>> g_scrollOverviews;

// Tells the shell (quickshell ii) to reveal bar + dock while the overview is up.
// ponytail: one bool over the existing event socket, no new IPC channel.
static void emitOverviewState() {
    static bool lastOpen = false;
    const bool  OPEN     = !g_scrollOverviews.empty();
    if (OPEN == lastOpen || !g_pEventManager)
        return;
    lastOpen = OPEN;
    g_pEventManager->postEvent(SHyprIPCEvent{.event = "scrolloverview", .data = OPEN ? "1" : "0"});
}

const std::vector<SP<IOverview>>& scrollOverviews() {
    return g_scrollOverviews;
}

SP<IOverview> scrollOverviewForMonitor(PHLMONITOR monitor) {
    if (!monitor)
        return {};

    const auto IT = std::ranges::find_if(g_scrollOverviews, [&monitor](const auto& overview) {
        return overview && overview->pMonitor.lock() == monitor;
    });
    return IT == g_scrollOverviews.end() ? SP<IOverview>{} : *IT;
}

SP<IOverview> scrollOverviewAt(const Vector2D& point) {
    const auto IT = std::ranges::find_if(g_scrollOverviews, [&point](const auto& overview) {
        const auto monitor = overview ? overview->pMonitor.lock() : PHLMONITOR{};
        return monitor && monitor->logicalBox().containsPoint(point);
    });
    return IT == g_scrollOverviews.end() ? SP<IOverview>{} : *IT;
}

SP<IOverview> activeScrollOverview() {
    if (g_pInputManager) {
        if (const auto overview = scrollOverviewAt(g_pInputManager->getMouseCoordsInternal()))
            return overview;
    }

    if (const auto monitor = Desktop::focusState()->monitor()) {
        if (const auto overview = scrollOverviewForMonitor(monitor))
            return overview;
    }

    if (g_pScrollOverview && std::ranges::find(g_scrollOverviews, g_pScrollOverview) != g_scrollOverviews.end())
        return g_pScrollOverview;

    return g_scrollOverviews.empty() ? SP<IOverview>{} : g_scrollOverviews.front();
}

void registerScrollOverview(const SP<IOverview>& overview) {
    if (!overview || std::ranges::find(g_scrollOverviews, overview) != g_scrollOverviews.end())
        return;

    g_scrollOverviews.emplace_back(overview);
    g_pScrollOverview = overview;
    emitOverviewState();
}

// Overviews die from inside their own close animation: the last thing close() does
// is scale->setCallbackOnEnd([this]{ removeOverview(this); }). This vector holds the
// only strong reference, so erasing it there ran ~CScrollOverview *while the animation
// manager was standing in that variable's callback* -- destroying `scale` out from
// under its own caller. The manager then walked freed memory on the next event, which
// is why the crash landed on a later mouse move and not on the keystroke that closed
// the overview: "segfault at X ip X", a call through a dangling function pointer.
//
// ponytail: park the reference and let the event loop drop it one tick later. Nothing
// else about teardown has to move, and it fixes every caller rather than the one that
// happened to reproduce. Same doLater the dock already uses.
static std::vector<SP<IOverview>> g_dyingOverviews;

void unregisterScrollOverview(IOverview* overview) {
    if (!overview)
        return;

    for (const auto& candidate : g_scrollOverviews)
        if (candidate.get() == overview)
            g_dyingOverviews.emplace_back(candidate);

    std::erase_if(g_scrollOverviews, [overview](const auto& candidate) { return candidate.get() == overview; });
    g_pScrollOverview = activeScrollOverview();
    emitOverviewState();

    if (!g_dyingOverviews.empty() && g_pEventLoopManager)
        g_pEventLoopManager->doLater([] { g_dyingOverviews.clear(); });
}

void clearScrollOverviews() {
    auto overviews = std::move(g_scrollOverviews);
    g_scrollOverviews.clear();
    g_pScrollOverview.reset();
    emitOverviewState();
    overviews.clear();
}
