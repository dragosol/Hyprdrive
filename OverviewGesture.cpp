#include "OverviewGesture.hpp"

#include "scrollOverview.hpp"

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/helpers/Monitor.hpp>

void COverviewGesture::begin(const ITrackpadGesture::STrackpadGestureBegin& e) {
    ITrackpadGesture::begin(e);

    m_lastDelta   = 0.F;
    m_firstUpdate = true;

    if (!g_pScrollOverview) {
        if (!ensureScrollOverviewHooks())
            return;

        g_pScrollOverview = makeShared<CScrollOverview>(Desktop::focusState()->monitor()->m_activeWorkspace);
    } else {
        g_pScrollOverview->selectHoveredWorkspace();
        g_pScrollOverview->setClosing(true);
    }
}

void COverviewGesture::update(const ITrackpadGesture::STrackpadGestureUpdate& e) {
    if (m_firstUpdate) {
        m_firstUpdate = false;
        return;
    }

    m_lastDelta += distance(e);

    if (m_lastDelta <= 0.01) // plugin will crash if swipe ends at <= 0
        m_lastDelta = 0.01;

    g_pScrollOverview->onSwipeUpdate(m_lastDelta);
}

void COverviewGesture::end(const ITrackpadGesture::STrackpadGestureEnd& e) {
    g_pScrollOverview->setClosing(false);
    g_pScrollOverview->onSwipeEnd();
    g_pScrollOverview->resetSwipe();
}
