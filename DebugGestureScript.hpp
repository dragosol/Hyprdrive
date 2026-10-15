#pragma once

// SYNTHETIC TRACKPAD GESTURES, the pure half: `hyprdrive:debug gesture <script>`
// parsed into the exact event sequence a touchpad would produce. No Hyprland
// headers, so scripts/debug_gesture_test.cpp checks every expansion on the host;
// DebugGesture.cpp plays the steps into the compositor.
//
// Why: a headless (or nested) Hyprland has no touchpad, so no gesture of this
// plugin -- 3/4-finger overview open/close/scrub, the desktop swipe and its
// detents, keep_swipe, swipe_while_dragging -- could be exercised by a test.
// The steps go in where libinput's go in:
//   swipe / pinch  -> CInputManager::onSwipe* / onPinch*, the functions
//                     Hyprland's own IPointer listeners call: the event bus
//                     (FingerSwipe's listeners may swallow), then
//                     CTrackpadGestures (whichever ITrackpadGesture is bound
//                     for that finger count and direction), then the
//                     pointer-gestures protocol;
//   frame          -> FingerSwipe's raw-finger frame handler, the one
//                     TouchpadRaw calls per evdev SYN_REPORT.
//
// THE SCRIPT: steps separated by ';', run in order; `wait` and the macros'
// step spacing make it play over real time, so the compositor renders the
// frames in between (a scrub can be photographed mid-way with `hold`).
//
//   swipe begin F                     one libinput event each
//   swipe update F DX DY              (DX/DY: libinput delta units, about
//   swipe end [cancel]                 device px; up is negative DY)
//   pinch begin F
//   pinch update F SCALE [ROT [DX DY]]   SCALE is relative to the begin (1 = none)
//   pinch end [cancel]
//   frame [button] [ID:X:Y ...]       one raw touchpad frame: the touches that
//                                     are down (tracking id, position in mm) and
//                                     whether the clickpad button is held. An
//                                     empty `frame` is every finger lifted.
//   wait MS
//
// Macros (expanded here; the parse is what the test checks):
//   swipe F DIR DIST [STEPS [MS]] [hold]
//       begin, STEPS updates of DIST/STEPS toward DIR (up|down|left|right),
//       MS apart (default 12 x 8 ms), then end -- unless `hold`, which leaves
//       the gesture open for a later `swipe update ...` / `swipe end`.
//   pinch F in|out [SCALE [STEPS [MS]]] [hold]
//       scale 1 -> SCALE in STEPS updates. in/out are the CONFIG directions
//       (`pinchin` / `pinchout` in a gesture binding), and Hyprland 0.56 maps
//       them backwards from what the fingers do (TrackpadGestures.cpp: scale
//       < 1, fingers closing, is PINCH_OUT). So `out` is scale 1 -> 0.5 and
//       `in` is 1 -> 2.0 by default; SCALE must be < 1 for out, > 1 for in.
//   keep F DIR MM1 MM2 [STEPS [MS]]
//       keep_swipe: F fingers swipe MM1 mm as libinput's swipe, one finger
//       lifts (libinput then cancels its swipe and starts an (F-1)-finger one,
//       as it does after its 100 ms debounce), the rest travel MM2 mm more,
//       then lift. With keep_swipe on, the F-finger gesture carries on to the
//       end; off, it ends at the lift.
//   drag F DIR MM [STEPS [MS]]
//       swipe_while_dragging: one finger holds the clickpad button (a drag),
//       F more land and travel MM mm, lift, then the button is let go.
//       libinput sends no gesture at all for this -- only the raw frames.

#include "FingerSwipeModel.hpp"

#include <cmath>
#include <cstdint>
#include <expected>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

namespace ScrollOverview::DebugGestureScript {

    enum class EKind : uint8_t {
        SwipeBegin,
        SwipeUpdate,
        SwipeEnd,
        PinchBegin,
        PinchUpdate,
        PinchEnd,
        Frame,
        Wait,
    };

    struct SStep {
        EKind                      kind      = EKind::Wait;
        uint32_t                   fingers   = 0;
        double                     dx        = 0, dy = 0;
        double                     scale     = 1.0, rotation = 0.0;
        bool                       cancelled = false;
        uint32_t                   ms        = 0;
        FingerSwipeModel::SFrame   frame;
    };

    // libinput delta units per mm for the raw-finger macros' own swipe updates:
    // FingerSwipeModel's starting estimate, so a continued swipe moves at the
    // pace the libinput part did.
    inline constexpr double UNITS_PER_MM = 30.0;

    namespace detail {
        inline std::vector<std::string> words(std::string_view s) {
            std::vector<std::string> out;
            std::istringstream       in{std::string{s}};
            for (std::string w; in >> w;)
                out.push_back(w);
            return out;
        }
        inline bool num(const std::string& s, double& out) {
            if (s.empty())
                return false;
            try {
                size_t used = 0;
                out         = std::stod(s, &used);
                return used == s.size() && std::isfinite(out);
            } catch (...) { return false; }
        }
        inline bool count(const std::string& s, uint32_t& out, uint32_t lo, uint32_t hi) {
            double d = 0;
            if (!num(s, d) || d != std::floor(d) || d < lo || d > hi)
                return false;
            out = static_cast<uint32_t>(d);
            return true;
        }
        // DIR -> unit vector (screen coordinates: up is -y).
        inline bool dir(const std::string& s, double& ux, double& uy) {
            ux = uy = 0;
            if (s == "up")
                uy = -1;
            else if (s == "down")
                uy = 1;
            else if (s == "left")
                ux = -1;
            else if (s == "right")
                ux = 1;
            else
                return false;
            return true;
        }
        inline SStep wait(uint32_t ms) {
            return SStep{.kind = EKind::Wait, .ms = ms};
        }
        inline SStep frame(const std::vector<FingerSwipeModel::STouch>& t, bool button) {
            return SStep{.kind = EKind::Frame, .frame = {.touches = t, .button = button}};
        }
        // Optional trailing [STEPS [MS]] [hold] after `at`.
        inline std::expected<void, std::string> tail(const std::vector<std::string>& w, size_t at, uint32_t& steps, uint32_t& ms, bool* hold) {
            size_t i = at;
            if (i < w.size() && w[i] != "hold") {
                if (!count(w[i], steps, 1, 1000))
                    return std::unexpected("STEPS must be 1..1000, got '" + w[i] + "'");
                ++i;
                if (i < w.size() && w[i] != "hold") {
                    if (!count(w[i], ms, 0, 1000))
                        return std::unexpected("MS must be 0..1000, got '" + w[i] + "'");
                    ++i;
                }
            }
            if (i < w.size() && w[i] == "hold") {
                if (!hold)
                    return std::unexpected("'hold' is for swipe and pinch only");
                *hold = true;
                ++i;
            }
            if (i != w.size())
                return std::unexpected("unexpected '" + w[i] + "'");
            return {};
        }
    }

    inline std::expected<std::vector<SStep>, std::string> parse(std::string_view script) {
        using namespace detail;
        std::vector<SStep> out;
        size_t             start = 0;
        while (start <= script.size()) {
            const size_t SEMI = script.find(';', start);
            const auto   PART = script.substr(start, SEMI == std::string_view::npos ? std::string_view::npos : SEMI - start);
            start             = SEMI == std::string_view::npos ? script.size() + 1 : SEMI + 1;
            const auto W      = words(PART);
            if (W.empty())
                continue;
            const auto BAD = [&](const std::string& why) { return std::unexpected("'" + std::string{PART} + "': " + why); };
            const auto& V  = W[0];

            if (V == "wait") {
                uint32_t ms = 0;
                if (W.size() != 2 || !count(W[1], ms, 0, 60000))
                    return BAD("wait MS (0..60000)");
                out.push_back(wait(ms));
            } else if ((V == "swipe" || V == "pinch") && W.size() >= 2 && (W[1] == "begin" || W[1] == "update" || W[1] == "end")) {
                const bool SWIPE = V == "swipe";
                SStep      s;
                if (W[1] == "begin") {
                    if (W.size() != 3 || !count(W[2], s.fingers, 2, 9))
                        return BAD(V + " begin F (2..9)");
                    s.kind = SWIPE ? EKind::SwipeBegin : EKind::PinchBegin;
                } else if (W[1] == "end") {
                    if (W.size() > 3 || (W.size() == 3 && W[2] != "cancel"))
                        return BAD(V + " end [cancel]");
                    s.kind      = SWIPE ? EKind::SwipeEnd : EKind::PinchEnd;
                    s.cancelled = W.size() == 3;
                } else if (SWIPE) {
                    if (W.size() != 5 || !count(W[2], s.fingers, 2, 9) || !num(W[3], s.dx) || !num(W[4], s.dy))
                        return BAD("swipe update F DX DY");
                    s.kind = EKind::SwipeUpdate;
                } else {
                    if ((W.size() != 4 && W.size() != 5 && W.size() != 7) || !count(W[2], s.fingers, 2, 9) || !num(W[3], s.scale) || s.scale <= 0 ||
                        (W.size() >= 5 && !num(W[4], s.rotation)) || (W.size() == 7 && (!num(W[5], s.dx) || !num(W[6], s.dy))))
                        return BAD("pinch update F SCALE [ROT [DX DY]] (SCALE > 0)");
                    s.kind = EKind::PinchUpdate;
                }
                out.push_back(s);
            } else if (V == "swipe") {
                uint32_t F = 0, steps = 12, ms = 8;
                double   ux = 0, uy = 0, dist = 0;
                bool     hold = false;
                if (W.size() < 4 || !count(W[1], F, 2, 9) || !dir(W[2], ux, uy) || !num(W[3], dist) || dist < 0)
                    return BAD("swipe F up|down|left|right DIST [STEPS [MS]] [hold]");
                if (auto r = tail(W, 4, steps, ms, &hold); !r)
                    return BAD(r.error());
                out.push_back({.kind = EKind::SwipeBegin, .fingers = F});
                for (uint32_t i = 0; i < steps; ++i) {
                    if (ms)
                        out.push_back(wait(ms));
                    out.push_back({.kind = EKind::SwipeUpdate, .fingers = F, .dx = ux * dist / steps, .dy = uy * dist / steps});
                }
                if (!hold)
                    out.push_back({.kind = EKind::SwipeEnd});
            } else if (V == "pinch") {
                uint32_t F = 0, steps = 12, ms = 8;
                bool     hold = false;
                if (W.size() < 3 || !count(W[1], F, 2, 9) || (W[2] != "in" && W[2] != "out"))
                    return BAD("pinch F in|out [SCALE [STEPS [MS]]] [hold]");
                // Hyprland's naming, not the fingers' (see the header).
                double target = W[2] == "out" ? 0.5 : 2.0;
                size_t at     = 3;
                if (W.size() > 3 && W[3] != "hold") {
                    if (!num(W[3], target) || target <= 0 || (W[2] == "out" ? target >= 1 : target <= 1))
                        return BAD("SCALE must be < 1 for out (Hyprland's pinchout), > 1 for in");
                    at = 4;
                }
                if (auto r = tail(W, at, steps, ms, &hold); !r)
                    return BAD(r.error());
                out.push_back({.kind = EKind::PinchBegin, .fingers = F});
                for (uint32_t i = 1; i <= steps; ++i) {
                    if (ms)
                        out.push_back(wait(ms));
                    out.push_back({.kind = EKind::PinchUpdate, .fingers = F, .scale = 1.0 + (target - 1.0) * i / steps});
                }
                if (!hold)
                    out.push_back({.kind = EKind::PinchEnd});
            } else if (V == "frame") {
                SStep s{.kind = EKind::Frame};
                for (size_t i = 1; i < W.size(); ++i) {
                    if (W[i] == "button" && i == 1) {
                        s.frame.button = true;
                        continue;
                    }
                    const auto C1 = W[i].find(':'), C2 = W[i].find(':', C1 == std::string::npos ? 0 : C1 + 1);
                    double     id = 0, x = 0, y = 0;
                    if (C1 == std::string::npos || C2 == std::string::npos || !num(W[i].substr(0, C1), id) || id != std::floor(id) || id < 0 ||
                        !num(W[i].substr(C1 + 1, C2 - C1 - 1), x) || !num(W[i].substr(C2 + 1), y))
                        return BAD("frame [button] [ID:X:Y ...] (id a whole number >= 0, x/y in mm)");
                    s.frame.touches.push_back({.id = static_cast<int>(id), .x = x, .y = y});
                }
                out.push_back(s);
            } else if (V == "keep") {
                uint32_t F = 0, steps = 10, ms = 8;
                double   ux = 0, uy = 0, mm1 = 0, mm2 = 0;
                if (W.size() < 5 || !count(W[1], F, 3, 9) || !dir(W[2], ux, uy) || !num(W[3], mm1) || !num(W[4], mm2) || mm1 < 0 || mm2 < 0)
                    return BAD("keep F(3..9) up|down|left|right MM1 MM2 [STEPS [MS]]");
                if (auto r = tail(W, 5, steps, ms, nullptr); !r)
                    return BAD(r.error());
                std::vector<FingerSwipeModel::STouch> t;
                for (uint32_t i = 0; i < F; ++i)
                    t.push_back({.id = 10 + static_cast<int>(i), .x = 30.0 + 12.0 * i, .y = 40.0});
                const auto MOVE = [&](double mm) {
                    for (auto& T : t) {
                        T.x += ux * mm;
                        T.y += uy * mm;
                    }
                };
                // libinput's F-finger swipe, the raw frames under it.
                out.push_back(frame(t, false));
                out.push_back({.kind = EKind::SwipeBegin, .fingers = F});
                for (uint32_t i = 0; i < steps; ++i) {
                    if (ms)
                        out.push_back(wait(ms));
                    MOVE(mm1 / steps);
                    out.push_back(frame(t, false));
                    out.push_back({.kind = EKind::SwipeUpdate, .fingers = F, .dx = ux * mm1 / steps * UNITS_PER_MM, .dy = uy * mm1 / steps * UNITS_PER_MM});
                }
                // One finger lifts; libinput gives up on its swipe and, after
                // its debounce, starts an (F-1)-finger one.
                t.pop_back();
                out.push_back(frame(t, false));
                out.push_back({.kind = EKind::SwipeEnd, .cancelled = true});
                out.push_back({.kind = EKind::SwipeBegin, .fingers = F - 1});
                for (uint32_t i = 0; i < steps; ++i) {
                    if (ms)
                        out.push_back(wait(ms));
                    MOVE(mm2 / steps);
                    out.push_back(frame(t, false));
                    out.push_back({.kind = EKind::SwipeUpdate, .fingers = F - 1, .dx = ux * mm2 / steps * UNITS_PER_MM, .dy = uy * mm2 / steps * UNITS_PER_MM});
                }
                // Everything lifts.
                out.push_back(frame({}, false));
                out.push_back({.kind = EKind::SwipeEnd});
            } else if (V == "drag") {
                uint32_t F = 0, steps = 10, ms = 8;
                double   ux = 0, uy = 0, mm = 0;
                if (W.size() < 4 || !count(W[1], F, 3, 4) || !dir(W[2], ux, uy) || !num(W[3], mm) || mm < 0)
                    return BAD("drag F(3..4) up|down|left|right MM [STEPS [MS]]");
                if (auto r = tail(W, 4, steps, ms, nullptr); !r)
                    return BAD(r.error());
                const FingerSwipeModel::STouch        HELD{.id = 1, .x = 50.0, .y = 70.0};
                std::vector<FingerSwipeModel::STouch> t{HELD};
                out.push_back(frame(t, true)); // the drag's finger presses the button
                for (uint32_t i = 0; i < F; ++i)
                    t.push_back({.id = 10 + static_cast<int>(i), .x = 30.0 + 12.0 * i, .y = 40.0});
                out.push_back(frame(t, true));
                for (uint32_t i = 0; i < steps; ++i) {
                    if (ms)
                        out.push_back(wait(ms));
                    for (size_t k = 1; k < t.size(); ++k) {
                        t[k].x += ux * mm / steps;
                        t[k].y += uy * mm / steps;
                    }
                    out.push_back(frame(t, true));
                }
                out.push_back(frame({HELD}, true)); // the swiping fingers lift
                out.push_back(frame({}, false));    // then the button is let go
            } else
                return BAD("unknown step (swipe, pinch, frame, wait, keep, drag)");
        }
        if (out.empty())
            return std::unexpected("empty script");
        return out;
    }
}
