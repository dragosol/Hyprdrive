#include "OverviewGesture.hpp"

#include "scrollOverview.hpp"

#include <algorithm>
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/output/Monitor.hpp>

void COverviewGesture::begin(const ITrackpadGesture::STrackpadGestureBegin& e) {
    ITrackpadGesture::begin(e);

    m_lastDelta   = 0.F;
    m_firstUpdate = true;

    const auto MONITOR  = Desktop::focusState()->monitor();
    if (!MONITOR)
        return;

    auto       overview = scrollOverviewForMonitor(MONITOR);

    if (!overview) {
        if (!ensureScrollOverviewHooks())
            return;

        overview = makeShared<CScrollOverview>(MONITOR->m_activeWorkspace, true, MONITOR);
        registerScrollOverview(overview);
    } else {
        overview->selectHoveredWorkspace();
        overview->setClosing(true);
    }

    // No "current overview" pointer to update: the gesture always begins on the
    // FOCUSED monitor, which is activeScrollOverview()'s second tier, so the
    // write this used to make could never change an answer.
    m_overview = overview;
}

void COverviewGesture::update(const ITrackpadGesture::STrackpadGestureUpdate& e) {
    const auto OVERVIEW = m_overview.lock();
    if (!OVERVIEW)
        return;

    if (m_firstUpdate) {
        m_firstUpdate = false;
        return;
    }

    m_lastDelta += distance(e);

    if (m_lastDelta <= 0.01) // plugin will crash if swipe ends at <= 0
        m_lastDelta = 0.01;

    OVERVIEW->onSwipeUpdate(m_lastDelta);
}

void COverviewGesture::end(const ITrackpadGesture::STrackpadGestureEnd& e) {
    const auto OVERVIEW = m_overview.lock();
    if (OVERVIEW)
        OVERVIEW->onSwipeEnd();

    // Re-check the same instance since onSwipeEnd can finish its close.
    if (std::ranges::find(scrollOverviews(), OVERVIEW) != scrollOverviews().end())
        OVERVIEW->resetSwipe();
    m_overview.reset();
}
