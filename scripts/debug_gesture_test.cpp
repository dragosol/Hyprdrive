// Host test for DebugGestureScript.hpp -- the `hyprdrive:debug gesture` script
// parser -- and, through FingerSwipeModel, that the raw-finger macros really
// produce what keep_swipe and swipe_while_dragging act on: the same model
// FingerSwipe.cpp runs is fed the parsed steps here, in order.
#include "../DebugGestureScript.hpp"

#include <cstdio>
#include <string>

using namespace ScrollOverview;
using namespace ScrollOverview::DebugGestureScript;

static int g_checks = 0, g_failed = 0;
#define CHECK(c)                                                                                                                                                                   \
    do {                                                                                                                                                                           \
        ++g_checks;                                                                                                                                                                \
        if (!(c)) {                                                                                                                                                                \
            ++g_failed;                                                                                                                                                            \
            std::printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c);                                                                                                               \
        }                                                                                                                                                                          \
    } while (0)

static size_t countKind(const std::vector<SStep>& s, EKind k) {
    size_t n = 0;
    for (const auto& S : s)
        n += S.kind == k ? 1 : 0;
    return n;
}

// What the compositor side would see: feed the steps through the model the way
// DebugGesture.cpp does (libinput events to the model first; the ones it does
// not cancel reach Hyprland), and collect what reached Hyprland's gesture
// manager -- libinput's own, and the model's synthesized ones.
struct SSeen {
    int    begins = 0, ends = 0, cancelledEnds = 0, updates = 0;
    double travelY = 0, travelX = 0;
    uint32_t lastFingers = 0;
};
static SSeen run(const std::vector<SStep>& steps, bool keep, bool drag) {
    FingerSwipeModel::CModel m;
    m.cfg.keepSwipe = keep;
    m.cfg.dragSwipe = drag;
    SSeen      seen;
    const auto APPLY = [&](const FingerSwipeModel::SOut& o) {
        if (o.begin) {
            ++seen.begins;
            seen.lastFingers = o.fingers;
        }
        for (const auto& U : o.updates) {
            ++seen.updates;
            seen.travelX += U.x;
            seen.travelY += U.y;
        }
        if (o.end)
            ++seen.ends;
    };
    for (const auto& S : steps) {
        switch (S.kind) {
            case EKind::SwipeBegin:
                if (!m.onSwipeBegin(S.fingers).cancel) {
                    ++seen.begins;
                    seen.lastFingers = S.fingers;
                }
                break;
            case EKind::SwipeUpdate:
                if (!m.onSwipeUpdate(S.fingers, {S.dx, S.dy}).cancel) {
                    ++seen.updates;
                    seen.travelX += S.dx;
                    seen.travelY += S.dy;
                }
                break;
            case EKind::SwipeEnd:
                if (!m.onSwipeEnd(S.cancelled).cancel) {
                    ++seen.ends;
                    seen.cancelledEnds += S.cancelled ? 1 : 0;
                }
                break;
            case EKind::Frame: APPLY(m.onFrame(S.frame)); break;
            default: break;
        }
    }
    return seen;
}

int main() {
    // ---- plain events ------------------------------------------------------
    {
        const auto R = parse("swipe begin 3; swipe update 3 0 -40; swipe end");
        CHECK(R && R->size() == 3);
        CHECK(R && (*R)[0].kind == EKind::SwipeBegin && (*R)[0].fingers == 3);
        CHECK(R && (*R)[1].kind == EKind::SwipeUpdate && (*R)[1].dy == -40);
        CHECK(R && (*R)[2].kind == EKind::SwipeEnd && !(*R)[2].cancelled);
    }
    {
        const auto R = parse("pinch begin 4;pinch update 4 0.8 5 1 2;pinch end cancel;wait 30");
        CHECK(R && R->size() == 4);
        CHECK(R && (*R)[1].scale == 0.8 && (*R)[1].rotation == 5 && (*R)[1].dx == 1 && (*R)[1].dy == 2);
        CHECK(R && (*R)[2].kind == EKind::PinchEnd && (*R)[2].cancelled);
        CHECK(R && (*R)[3].kind == EKind::Wait && (*R)[3].ms == 30);
    }
    {
        const auto R = parse("frame button 1:10.5:20 2:30:20");
        CHECK(R && R->size() == 1 && (*R)[0].frame.button && (*R)[0].frame.touches.size() == 2 && (*R)[0].frame.touches[0].x == 10.5);
        const auto E = parse("frame");
        CHECK(E && E->size() == 1 && E->front().frame.touches.empty() && !E->front().frame.button);
    }

    // ---- macros ------------------------------------------------------------
    {
        const auto R = parse("swipe 3 up 300");
        CHECK(R && countKind(*R, EKind::SwipeBegin) == 1 && countKind(*R, EKind::SwipeUpdate) == 12 && countKind(*R, EKind::SwipeEnd) == 1);
        double y = 0;
        for (const auto& S : *R)
            y += S.kind == EKind::SwipeUpdate ? S.dy : 0;
        CHECK(R && std::abs(y + 300) < 1e-9);
        CHECK(R && countKind(*R, EKind::Wait) == 12 && (*R)[1].ms == 8);
    }
    {
        const auto R = parse("swipe 4 left 500 5 0 hold");
        CHECK(R && countKind(*R, EKind::SwipeUpdate) == 5 && countKind(*R, EKind::SwipeEnd) == 0 && countKind(*R, EKind::Wait) == 0);
        CHECK(R && (*R)[1].dx == -100);
    }
    {
        // Hyprland's direction names: pinchout is scale < 1.
        const auto R = parse("pinch 4 out");
        CHECK(R && countKind(*R, EKind::PinchUpdate) == 12 && R->back().kind == EKind::PinchEnd);
        CHECK(R && (*R)[R->size() - 2].scale == 0.5);
        const auto I = parse("pinch 3 in 2.5 4 10 hold");
        CHECK(I && countKind(*I, EKind::PinchUpdate) == 4 && countKind(*I, EKind::PinchEnd) == 0 && (*I).back().scale == 2.5);
    }

    // ---- errors ------------------------------------------------------------
    CHECK(!parse(""));
    CHECK(!parse(" ; ;"));
    CHECK(!parse("swipe begin 1"));  // one finger is not a gesture
    CHECK(!parse("swipe 3 sideways 100"));
    CHECK(!parse("swipe 3 up -5"));
    CHECK(!parse("swipe 3 up 100 0"));        // zero steps
    CHECK(!parse("swipe 3 up 100 4 8 hold x"));
    CHECK(!parse("pinch 3 out 1.5"));         // out (pinchout) is scale < 1
    CHECK(!parse("pinch 3 in 0.5"));
    CHECK(!parse("pinch update 3 0"));        // scale 0
    CHECK(!parse("frame 1:2"));
    CHECK(!parse("keep 3 up 10 10 hold"));    // hold is swipe/pinch only
    CHECK(!parse("drag 5 up 10"));            // the model knows 3 and 4
    CHECK(!parse("wiggle"));
    {
        const auto E = parse("swipe 3 up 100; bogus 1");
        CHECK(!E && E.error().find("bogus") != std::string::npos);
    }

    // ---- what the raw-finger macros do to the real model ---------------------
    {
        const auto R = parse("keep 3 up 10 20 10 0");
        CHECK(R.has_value());
        // keep_swipe ON: libinput's begin + its 10 updates reach Hyprland, its
        // cancel and its 2-finger restart do not; the model carries the
        // remaining 20 mm as updates and ends the swipe once, not cancelled.
        const auto ON = run(*R, true, true);
        CHECK(ON.begins == 1 && ON.ends == 1 && ON.cancelledEnds == 0);
        CHECK(ON.lastFingers == 3);
        CHECK(std::abs(ON.travelY + 30 * UNITS_PER_MM) < 1e-6); // 10 mm libinput + 20 mm carried
        // OFF: libinput's story as is -- the 3-finger swipe ends cancelled at
        // the lift and a 2-finger one runs to the end.
        const auto OFF = run(*R, false, true);
        CHECK(OFF.begins == 2 && OFF.ends == 2 && OFF.cancelledEnds == 1);
        CHECK(OFF.lastFingers == 2);
    }
    {
        const auto R = parse("drag 3 left 20 10 0");
        CHECK(R.has_value());
        // swipe_while_dragging ON: no libinput gesture at all, yet one 3-finger
        // swipe begins, travels left and ends.
        const auto ON = run(*R, true, true);
        CHECK(ON.begins == 1 && ON.ends == 1 && ON.lastFingers == 3);
        CHECK(ON.travelX < -15 * UNITS_PER_MM && ON.travelY == 0);
        const auto OFF = run(*R, true, false);
        CHECK(OFF.begins == 0 && OFF.ends == 0 && OFF.updates == 0);
    }

    std::printf("debug_gesture_test: %d checks, %d failed\n", g_checks, g_failed);
    return g_failed ? 1 : 0;
}
