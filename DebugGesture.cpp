// See DebugGesture.hpp and DebugGestureScript.hpp.
#include "DebugGesture.hpp"

#include "DebugGestureScript.hpp"
#include "FingerSwipe.hpp"
#include "GestureDrive.hpp"
#include "IOverview.hpp"

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/helpers/time/Time.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>

#include <deque>
#include <format>

namespace ScrollOverview::DebugGesture {
    namespace {
        using DebugGestureScript::EKind;
        using DebugGestureScript::SStep;

        std::deque<SStep> g_queue;
        wl_event_source*  g_timer   = nullptr;
        size_t            g_played  = 0;     // steps fed since load (the report's progress counter)
        bool              g_armed   = false; // the timer is set (a wait, or the first step)

        uint32_t nowMs() {
            return sc<uint32_t>(Time::millis(Time::steadyNow()));
        }

        // One step, into the entry point a real touchpad's event takes.
        void feed(const SStep& s) {
            const auto T = nowMs();
            switch (s.kind) {
                case EKind::SwipeBegin: g_pInputManager->onSwipeBegin({.timeMs = T, .fingers = s.fingers}); break;
                case EKind::SwipeUpdate: g_pInputManager->onSwipeUpdate({.timeMs = T, .fingers = s.fingers, .delta = {s.dx, s.dy}}); break;
                case EKind::SwipeEnd: g_pInputManager->onSwipeEnd({.timeMs = T, .cancelled = s.cancelled}); break;
                case EKind::PinchBegin: g_pInputManager->onPinchBegin({.timeMs = T, .fingers = s.fingers}); break;
                case EKind::PinchUpdate:
                    g_pInputManager->onPinchUpdate({.timeMs = T, .fingers = s.fingers, .delta = {s.dx, s.dy}, .scale = s.scale, .rotation = s.rotation});
                    break;
                case EKind::PinchEnd: g_pInputManager->onPinchEnd({.timeMs = T, .cancelled = s.cancelled}); break;
                case EKind::Frame: FingerSwipe::debugFrame(s.frame); break;
                case EKind::Wait: break;
            }
            ++g_played;
        }

        // Play until the queue is empty or a wait; a wait re-arms the timer.
        // Never more than the queue held on entry plus nothing new: a step
        // cannot enqueue (only the dispatcher does).
        int pump(void*) {
            g_armed = false;
            while (!g_queue.empty()) {
                const SStep S = g_queue.front();
                g_queue.pop_front();
                if (S.kind == EKind::Wait) {
                    if (S.ms > 0) {
                        g_armed = true;
                        wl_event_source_timer_update(g_timer, sc<int>(S.ms));
                        return 0;
                    }
                    continue;
                }
                if (!g_pInputManager)
                    continue;
                feed(S);
            }
            return 0;
        }
    }

    std::string run(std::string_view script, bool& isReport) {
        isReport = false;
        while (!script.empty() && (script.front() == ' ' || script.front() == '\t'))
            script.remove_prefix(1);
        while (!script.empty() && (script.back() == ' ' || script.back() == '\t'))
            script.remove_suffix(1);

        if (script == "state") {
            isReport   = true;
            size_t open = 0;
            for (const auto& O : scrollOverviews())
                if (O && !O->isClosing())
                    ++open;
            return std::format("hyprdrive gesture: finger model {}, trackpad gesture {}, {} step(s) queued, {} played, {} overview(s) open",
                               FingerSwipe::debugMode(), GestureDrive::active() ? "ACTIVE" : "none", g_queue.size(), g_played, open);
        }
        if (script == "stop") {
            g_queue.clear();
            g_armed = false;
            if (g_timer)
                wl_event_source_timer_update(g_timer, 0);
            return {};
        }

        auto steps = DebugGestureScript::parse(script);
        if (!steps)
            return "hyprdrive:debug gesture: " + steps.error();
        if (!g_timer)
            g_timer = wl_event_loop_add_timer(g_pCompositor->m_wlEventLoop, pump, nullptr);
        if (!g_timer)
            return "hyprdrive:debug gesture: no event-loop timer";
        g_queue.insert(g_queue.end(), steps->begin(), steps->end());
        // Not played inside the dispatcher: from the loop, 1 ms on, like input.
        // Already playing (a wait pending): the new steps follow it.
        if (!g_armed) {
            g_armed = true;
            wl_event_source_timer_update(g_timer, 1);
        }
        return {};
    }

    void shutdown() {
        g_queue.clear();
        g_armed = false;
        if (g_timer)
            wl_event_source_remove(g_timer);
        g_timer = nullptr;
    }
}
