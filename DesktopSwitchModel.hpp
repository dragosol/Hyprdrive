#pragma once

// DESKTOP SWITCHES, the pure half (user, 2026-10-15). Three small decisions the
// live half (DesktopSwitch.cpp) makes with Hyprland state in hand, kept free of
// Hyprland headers so scripts/desktop_switch_test.cpp runs them on the host:
//
//   - where Super+scroll goes: the next / previous desktop BY NUMBER on the
//     focused monitor, so empty desktops are visited too (Hyprland's own
//     "r+1"/"r-1"), clamped to 1..max(10, the highest desktop that monitor
//     has) -- no wrap -- and never onto a number another monitor owns;
//   - one step per wheel NOTCH: a high-resolution wheel reports a notch as
//     several sub-notch events (value120 units, 120 to the notch), each of which
//     fires the mouse_down/mouse_up bind, so the bind only steps once a whole
//     notch has accumulated;
//   - what CAUSED a desktop switch, for animation:desktop_keyboard /
//     animation:desktop_focus: a key or scroll bind, focus moving to a window on
//     another desktop, or anything else (left alone).

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <functional>

namespace ScrollOverview::DesktopSwitch {

    // The lowest and highest desktop Super+scroll walks between on a monitor
    // whose highest existing desktop is `highestOnMonitor` (0 when it has none).
    inline constexpr int64_t FIRST_DESKTOP     = 1;
    inline constexpr int64_t MIN_LAST_DESKTOP  = 10;

    constexpr int64_t lastDesktop(int64_t highestOnMonitor) {
        return std::max(MIN_LAST_DESKTOP, highestOnMonitor);
    }

    // The desktop one step from `current` in `dir` (+1 next, -1 previous), or
    // `current` itself when there is nowhere to go (the clamp, or every number
    // in that direction belongs to another monitor). `ownedElsewhere(id)` says a
    // desktop number is another monitor's: stepping skips it, the way r+1 does,
    // instead of yanking that desktop over here or focusing that monitor.
    //
    // A named desktop (negative id) is outside the numbers: either direction
    // goes to the first desktop. A current desktop past the last one (the
    // caller's highest did not count it) has nothing after it, and steps back
    // to the last.
    inline int64_t stepTarget(int64_t current, int dir, int64_t highestOnMonitor, const std::function<bool(int64_t)>& ownedElsewhere = {}) {
        if (dir == 0)
            return current;
        const auto    FREE = [&](int64_t n) { return !ownedElsewhere || !ownedElsewhere(n); };
        const int64_t LAST = lastDesktop(highestOnMonitor);
        const int64_t STEP = dir > 0 ? 1 : -1;
        if (current < FIRST_DESKTOP) {
            for (int64_t n = FIRST_DESKTOP; n <= LAST; ++n)
                if (FREE(n))
                    return n;
            return current;
        }
        int64_t id = current;
        if (id > LAST) {
            if (STEP > 0)
                return current;
            id = LAST + 1;
        }
        for (id += STEP; id >= FIRST_DESKTOP && id <= LAST; id += STEP)
            if (FREE(id))
                return id;
        return current;
    }

    // value120 units, as libinput and Hyprland's SAxisEvent::deltaDiscrete count
    // them: one detent of an ordinary wheel.
    inline constexpr int NOTCH = 120;

    // Sub-notch wheel events add up to a notch; each notch pays for one step.
    // feed() sees EVERY wheel event (an axis listener runs before Hyprland's
    // scroll_event_delay throttle, which lets the bind see only the first event
    // of a burst), take() is asked when the bind fires. A bind that fires on a
    // part of a notch cannot step yet, so it leaves the step PENDING, and the
    // feed() that completes the notch answers with it (the caller steps then)
    // -- the step lands with the notch instead of waiting for the next one.
    // A pause or a change of direction starts over, and at most one notch is
    // banked beyond the one being spent, so a long spin does not keep stepping
    // after the wheel stops.
    struct SNotchAccumulator {
        int      accum   = 0;
        int      pending = 0; // a bind's step waiting for its notch: +1 / -1
        uint32_t lastMs  = 0;
        bool     seen    = false;

        static constexpr uint32_t IDLE_MS = 1000;

        // -> the direction to step NOW (a pending step whose notch just
        // completed), or 0.
        int feed(int value120, uint32_t timeMs) {
            if (value120 == 0)
                return 0;
            const bool IDLE    = seen && (timeMs < lastMs || timeMs - lastMs > IDLE_MS);
            const bool REVERSE = (accum > 0 && value120 < 0) || (accum < 0 && value120 > 0);
            if (!seen || IDLE || REVERSE) {
                accum   = 0;
                pending = 0;
            }
            seen   = true;
            lastMs = timeMs;
            accum  = std::clamp(accum + value120, -2 * NOTCH, 2 * NOTCH);
            if (pending != 0 && spend(pending)) {
                const int DIR = pending;
                pending       = 0;
                return DIR;
            }
            return 0;
        }

        // The bind fired: one step's worth in `dir`, spent if it is there;
        // otherwise the step waits for the rest of its notch (feed()).
        bool take(int dir) {
            if (spend(dir))
                return true;
            pending = dir > 0 ? 1 : -1;
            return false;
        }

        bool spend(int dir) {
            if (dir > 0 && accum >= NOTCH) {
                accum -= NOTCH;
                return true;
            }
            if (dir < 0 && accum <= -NOTCH) {
                accum += NOTCH;
                return true;
            }
            return false;
        }

        void reset() {
            accum   = 0;
            pending = 0;
            seen    = false;
        }
    };

    enum class ECause : uint8_t {
        Other,    // a swipe, a script's `hyprctl dispatch workspace`, the overview...
        Keyboard, // a key or scroll bind (or hyprdrive's own desktop dispatcher)
        Focus,    // focus moving to a window on another desktop
    };

    // A bind running wins: a key bound to "focus that window" is still a key.
    constexpr ECause classify(bool ownDispatcher, bool bindRunning, bool focusPath) {
        if (ownDispatcher || bindRunning)
            return ECause::Keyboard;
        if (focusPath)
            return ECause::Focus;
        return ECause::Other;
    }

    struct SSnapFacts {
        ECause cause            = ECause::Other;
        bool   special          = false; // a special workspace (scratchpad...) sliding in/out
        bool   overview         = false; // an overview (open or closing) owns the monitor
        bool   animationEnabled = true;  // Hyprland would animate this switch at all
        bool   animateKeyboard  = true;  // animation:desktop_keyboard
        bool   animateFocus     = true;  // animation:desktop_focus
    };

    // Whether this desktop switch lands in one frame instead of animating.
    // Never with the overview up (its own transitions are its business), never
    // for a special workspace, and a no-op when Hyprland would not animate it
    // anyway.
    constexpr bool snap(const SSnapFacts& f) {
        if (f.special || f.overview || !f.animationEnabled)
            return false;
        switch (f.cause) {
            case ECause::Keyboard: return !f.animateKeyboard;
            case ECause::Focus: return !f.animateFocus;
            case ECause::Other: return false;
        }
        return false;
    }
}
