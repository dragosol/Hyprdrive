// Host test for DesktopSwitchModel.hpp: Super+scroll's stepping and clamping
// (empty desktops visited, no wrap, other monitors' numbers skipped), the
// one-step-per-notch accumulator, and the desktop-switch cause / snap decision.
#include "../DesktopSwitchModel.hpp"

#include <cstdio>
#include <set>

using namespace ScrollOverview::DesktopSwitch;

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
    // ---- stepping: by number, empty desktops included, clamped, no wrap
    static_assert(lastDesktop(0) == 10);
    static_assert(lastDesktop(14) == 14);
    CHECK(stepTarget(1, +1, 1) == 2);   // 2 does not exist yet: it is visited
    CHECK(stepTarget(2, +1, 1) == 3);
    CHECK(stepTarget(3, -1, 3) == 2);
    CHECK(stepTarget(1, -1, 5) == 1);   // clamps at 1
    CHECK(stepTarget(10, +1, 3) == 10); // clamps at 10 ...
    CHECK(stepTarget(10, +1, 12) == 11); // ... or at the highest desktop past it
    CHECK(stepTarget(12, +1, 12) == 12);
    CHECK(stepTarget(5, 0, 5) == 5);
    // Walking 1 -> 3 and back, one call per notch.
    int64_t id = 1;
    id         = stepTarget(id, +1, 1);
    id         = stepTarget(id, +1, 2);
    CHECK(id == 3);
    id = stepTarget(id, -1, 3);
    id = stepTarget(id, -1, 3);
    id = stepTarget(id, -1, 3);
    CHECK(id == 1);

    // Numbers another monitor owns are skipped, not stolen.
    const std::set<int64_t> OTHER{2, 3};
    const auto              ELSEWHERE = [&](int64_t n) { return OTHER.contains(n); };
    CHECK(stepTarget(1, +1, 1, ELSEWHERE) == 4);
    CHECK(stepTarget(4, -1, 4, ELSEWHERE) == 1);
    const std::set<int64_t> ALL{2, 3, 4, 5, 6, 7, 8, 9, 10};
    CHECK(stepTarget(1, +1, 1, [&](int64_t n) { return ALL.contains(n); }) == 1); // nowhere to go

    // Outside the range: from the nearest end.
    CHECK(stepTarget(-98, +1, 0) == 1); // a named desktop
    CHECK(stepTarget(-98, -1, 0) == 1);
    CHECK(stepTarget(15, -1, 3) == 10);
    CHECK(stepTarget(15, +1, 3) == 15);
    CHECK(stepTarget(-98, +1, 0, ELSEWHERE) == 1);

    // ---- one step per notch
    SNotchAccumulator a;
    a.feed(120, 1000); // an ordinary wheel: one event per notch
    CHECK(a.take(+1));
    CHECK(!a.take(+1));
    a.feed(-120, 1100);
    CHECK(!a.take(+1));
    CHECK(a.take(-1));

    // A hi-res wheel: four 30-unit events make one notch. The bind fires on the
    // first of them (scroll_event_delay swallows the rest), which pays for
    // nothing yet: the step waits, and the event completing the notch answers it.
    SNotchAccumulator h;
    CHECK(h.feed(30, 2000) == 0);
    CHECK(!h.take(+1));
    CHECK(h.feed(30, 2008) == 0);
    CHECK(h.feed(30, 2016) == 0);
    CHECK(h.feed(30, 2024) == +1); // the notch is complete: step now
    CHECK(h.feed(30, 2400) == 0);  // the next notch's first event...
    CHECK(!h.take(+1));            // ...fires the bind, which waits again
    CHECK(h.feed(30, 2408) == 0);
    CHECK(h.feed(30, 2416) == 0);
    CHECK(h.feed(30, 2424) == +1);
    // A quarter notch never steps.
    CHECK(h.feed(30, 2900) == 0);
    CHECK(!h.take(+1));
    CHECK(h.feed(-30, 2910) == 0); // and a reversal drops its pending step
    CHECK(h.pending == 0);

    // Eight 15-unit events with the bind firing on every one (no throttle) are
    // one notch, not eight steps.
    SNotchAccumulator f;
    int               steps = 0;
    for (int i = 0; i < 8; ++i) {
        steps += f.feed(15, 3000 + i * 4) != 0 ? 1 : 0;
        steps += f.take(+1) ? 1 : 0;
    }
    CHECK(steps == 1);

    // A pause or a reversal starts over; at most two notches are ever banked.
    SNotchAccumulator p;
    p.feed(90, 4000);
    p.feed(90, 6000); // after a pause (> 1 s): 90, not 180
    CHECK(!p.take(+1));
    CHECK(p.feed(-60, 6010) == 0); // reversal: -60, the pending +1 dropped
    CHECK(!p.take(-1));
    CHECK(p.feed(-60, 6020) == -1);
    SNotchAccumulator big;
    for (int i = 0; i < 10; ++i)
        big.feed(120, 7000 + i);
    CHECK(big.take(+1));
    CHECK(big.take(+1));
    CHECK(!big.take(+1));

    // ---- what caused the switch, and whether it snaps
    static_assert(classify(true, false, false) == ECause::Keyboard);
    static_assert(classify(false, true, true) == ECause::Keyboard); // a key bound to focuswindow
    static_assert(classify(false, false, true) == ECause::Focus);
    static_assert(classify(false, false, false) == ECause::Other);

    SSnapFacts k{.cause = ECause::Keyboard};
    CHECK(!snap(k));
    k.animateKeyboard = false;
    CHECK(snap(k));
    k.animateFocus = true;
    k.cause        = ECause::Focus; // the other toggle is untouched
    CHECK(!snap(k));
    k.animateFocus = false;
    CHECK(snap(k));
    k.cause = ECause::Other; // a swipe, a script: never
    CHECK(!snap(k));

    SSnapFacts g{.cause = ECause::Keyboard, .animateKeyboard = false};
    g.overview = true;
    CHECK(!snap(g)); // the overview's own switches are left alone
    g.overview = false;
    g.special  = true;
    CHECK(!snap(g));
    g.special          = false;
    g.animationEnabled = false; // already instant: nothing to do
    CHECK(!snap(g));

    std::printf("%d checks, %d failed\n", g_checks, g_failed);
    return g_failed == 0 ? 0 : 1;
}
