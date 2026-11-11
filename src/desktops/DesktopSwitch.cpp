// See DesktopSwitch.hpp; the decisions are DesktopSwitchModel.hpp.
#include "FullscreenGuard.hpp"
#include "DesktopSwitch.hpp"
#include "Rows.hpp"
#include "FunctionHooks.hpp"
#include "DesktopSwitchModel.hpp"
#include "DesktopRowModel.hpp"
#include "DesktopStrip.hpp"

#include "Config.hpp"
#include "IOverview.hpp"
#include "Mosaic.hpp"
#include "globals.hpp"

#include <hyprland/src/animation/WorkspaceAnimationController.hpp>
#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/config/shared/animation/AnimationTree.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/KeybindManager.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>

#include <algorithm>
#include <format>
#include <optional>
#include <string>
#include <vector>

namespace Hyprdrive::DesktopSwitch {
    namespace {
        CFunctionHook* g_startAnimHook  = nullptr;
        CFunctionHook* g_fullFocusHook  = nullptr;
        CFunctionHook* g_rawFocusHook   = nullptr; // focus following the mouse comes this way
        CFunctionHook* g_actionFocusHook = nullptr;

        CHyprSignalListener g_axis;

        // What is running right now. Depths, not flags: a focus call can nest
        // (the dock's activation focuses, and changeWorkspace focuses inside it).
        int g_ownDispatch = 0;
        int g_focusDepth  = 0;

        SNotchAccumulator g_notches;

        // The desktop strip (DesktopStrip.hpp).
        constexpr const char* KEY_SMOOTH     = "plugin:hyprdrive:binds:scroll_desktops_smooth";
        constexpr const char* KEY_TICKS      = "plugin:hyprdrive:binds:scroll_desktops_ticks";
        constexpr const char* KEY_STICKY     = "plugin:hyprdrive:binds:scroll_desktops_sticky";
        constexpr const char* KEY_STOP_EMPTY = "plugin:hyprdrive:binds:scroll_desktops_stop_at_empty";
        constexpr const char* KEY_POPULATED  = "plugin:hyprdrive:binds:scroll_desktops_populated_only";
        constexpr const char* KEY_BOUNCE     = "plugin:hyprdrive:animation:desktop_row_bounce";
        constexpr const char* KEY_JUMP       = "plugin:hyprdrive:animation:desktop_jump_through";

        // A switch in progress: the desktop its OUT half took away, and where
        // that one was on screen before Hyprland moved it (hkStartAnimation).
        int      g_switchFrom = 0;
        Vector2D g_switchFromOffset;

        // THE ROW the wheel walks on `monitor` (DesktopRowModel.hpp), `current`
        // shown: binds:scroll_desktops_stop_at_empty / _populated_only.
        //
        // ON THE MONITOR'S ROW (Rows.hpp): the model walks the row's PLACES
        // (1, 2, ... -- a block's 10, then its overflow), and the ids come back
        // from them; desktops outside the row (visitors, other blocks) are not
        // in it. Blocks off: place == id, the global number line.
        std::vector<int> rowOn(const PHLMONITOR& monitor, int current) {
            const Row ROW = Rows::of(monitor);
            DesktopRow::SFacts f{.current       = ROW.contains(current) ? sc<int>(ROW.slot(current)) : 0,
                                 .stopAtEmpty   = Config::getValue<Hyprlang::INT>(KEY_STOP_EMPTY) != 0,
                                 .populatedOnly = Config::getValue<Hyprlang::INT>(KEY_POPULATED) != 0};
            if (!ROW.bounded())
                f.current = current;
            for (const auto& REF : State::workspaceState()->workspaces()) {
                const auto WS = REF.lock();
                if (!WS || WS->m_isSpecialWorkspace || WS->m_id < DesktopRow::FIRST || !ROW.contains(WS->m_id))
                    continue;
                const int PLACE = sc<int>(ROW.slot(WS->m_id));
                if (WS->m_monitor.lock() != monitor) {
                    f.elsewhere.push_back(PLACE);
                    continue;
                }
                f.existing.push_back(PLACE);
                if (WS->getWindowCount() > 0)
                    f.populated.push_back(PLACE);
            }
            std::vector<int> out;
            for (const int PLACE : DesktopRow::row(f))
                if (const auto ID = ROW.idOf(PLACE); ID > 0 && PLACE >= 1)
                    out.push_back(sc<int>(ID));
            return out;
        }

        StripModel::SSettings stripSettings() {
            return {.smooth = Config::getValue<Hyprlang::INT>(KEY_SMOOTH) != 0,
                    .ticks  = std::clamp(sc<int>(Config::getValue<Hyprlang::INT>(KEY_TICKS)), 1, 10),
                    .sticky = Config::getValue<Hyprlang::INT>(KEY_STICKY) != 0,
                    .bounce = Config::getValue<Hyprlang::INT>(KEY_BOUNCE) != 0};
        }

        // FROM WHERE IT IS (user, 2026-11-02: "I always want stuff to be
        // reversible"). Hyprland starts a switch by sliding the desktop going
        // out from wherever it is, but WARPS the one coming in a whole screen
        // away first: scrolling back mid-slide, or on to the next one, jumped.
        // The one coming in now starts right beside the one going out, where
        // it is this frame: back mid-way, it is the desktop that was leaving,
        // turned around where it stood; on to a third, it follows the second
        // in like the next card in a strip. The same slide, toward the same
        // place (setValue: no warp, so the one going out is still drawn).
        void continueFromHere(const PHLWORKSPACE& in) {
            const auto MONITOR = in->m_monitor.lock();
            if (!MONITOR || !in->m_renderOffset)
                return;
            const Vector2D START = in->m_renderOffset->value(); // the side it comes from, a screen away
            if (std::abs(START.x) < 0.5 && std::abs(START.y) < 0.5)
                return; // not a slide (fade, or no animation)
            // The one going out heads exactly the other way, a screen off. Two
            // can (a third notch: the first desktop is still sliding away too):
            // it is the one most on screen.
            PHLWORKSPACE out;
            for (const auto& REF : State::workspaceState()->workspaces()) {
                const auto WS = REF.lock();
                if (!WS || WS == in || WS->m_isSpecialWorkspace || WS->m_monitor != MONITOR || !WS->m_renderOffset || !WS->m_renderOffset->isBeingAnimated())
                    continue;
                const Vector2D GOAL = WS->m_renderOffset->goal();
                if (std::abs(GOAL.x + START.x) > 1.0 || std::abs(GOAL.y + START.y) > 1.0)
                    continue;
                if (!out || WS->m_renderOffset->value().size() < out->m_renderOffset->value().size())
                    out = WS;
            }
            if (!out)
                return;
            const Vector2D NOW = out->m_renderOffset->value();
            if (std::abs(NOW.x) < 0.5 && std::abs(NOW.y) < 0.5)
                return; // it was at rest: an ordinary switch
            in->m_renderOffset->setValue(NOW + START);
        }

        // For `debug desktop`.
        ECause      g_lastCause = ECause::Other;
        bool        g_lastSnap  = false;
        WORKSPACEID g_lastWs    = WORKSPACE_INVALID;
        int         g_snaps     = 0;
        int         g_animated  = 0;

        const char* causeName(ECause c) {
            switch (c) {
                case ECause::Keyboard: return "keyboard";
                case ECause::Focus: return "focus";
                case ECause::Other: return "other";
            }
            return "?";
        }

        bool bindRunning() {
            return g_pKeybindManager && g_pKeybindManager->m_currentKeybind;
        }

        // The wheel bind is running: this call is one wheel event, which pays
        // for a step only once a whole notch has come in.
        bool wheelBindRunning() {
            if (!bindRunning())
                return false;
            const auto& KEY = g_pKeybindManager->m_currentKeybind->key;
            return KEY == "mouse_down" || KEY == "mouse_up";
        }

        // Would Hyprland animate this workspace at all? animations:enabled and
        // the workspaces / specialWorkspace leaf (Omarchy's looknfeel turns the
        // former leaf off). Off: there is nothing to make instant.
        bool hyprlandAnimates(const PHLWORKSPACE& ws, Animation::Workspace::eAnimationType type) {
            static auto PENABLED = CConfigValue<::Config::INTEGER>("animations:enabled");
            if (!*PENABLED)
                return false;
            const std::string NAME = std::format("{}{}", ws->m_isSpecialWorkspace ? "specialWorkspace" : "workspaces",
                                                 type == Animation::Workspace::ANIMATION_TYPE_IN ? "In" : "Out");
            const auto        CFG  = ::Config::animationTree()->getAnimationPropertyConfig(NAME);
            if (!CFG)
                return true;
            const auto VALUES = CFG->pValues.lock();
            return !VALUES || VALUES->internalEnabled != 0;
        }

        bool decide(const PHLWORKSPACE& ws, Animation::Workspace::eAnimationType type) {
            const auto MONITOR = ws->m_monitor.lock();
            SSnapFacts facts{
                .cause            = classify(g_ownDispatch > 0, bindRunning(), g_focusDepth > 0),
                .special          = ws->m_isSpecialWorkspace,
                .overview         = MONITOR && scrollOverviewForMonitor(MONITOR) != nullptr,
                .animationEnabled = hyprlandAnimates(ws, type),
                .animateKeyboard  = Config::getAnimateDesktopKeyboard(),
                .animateFocus     = Config::getAnimateDesktopFocus(),
            };
            const bool SNAP = snap(facts);
            // Recorded for the switch's IN half, which is the desktop arriving.
            if (type == Animation::Workspace::ANIMATION_TYPE_IN && !ws->m_isSpecialWorkspace) {
                g_lastCause = facts.cause;
                g_lastSnap  = SNAP;
                g_lastWs    = ws->m_id;
                ++(SNAP ? g_snaps : g_animated);
            }
            return SNAP;
        }

        // ANIMATION:DESKTOP_JUMP_THROUGH (user, 2026-11-02): a key or the dock
        // jumping several desktops slides past the ones between.
        bool jumpThrough() {
            const auto CAUSE = classify(g_ownDispatch > 0, bindRunning(), g_focusDepth > 0);
            return (CAUSE == ECause::Keyboard || CAUSE == ECause::Focus) && Config::getValue<Hyprlang::INT>(KEY_JUMP) != 0;
        }

        // ---- hooks
        // Whose slide a switch is: the strip's own switch, or one the strip
        // claims (it is moving, or a jump through) -- Hyprland's half lands at
        // once and the strip draws; a cause whose switch is off lands at once;
        // otherwise Hyprland's, continued from where things are. OUT starts
        // first (changeWorkspace), with the new desktop already active.
        using origStartAnimation = void (*)(PHLWORKSPACE, Animation::Workspace::eAnimationType, bool, bool, std::optional<std::string>);
        void hkStartAnimation(PHLWORKSPACE ws, Animation::Workspace::eAnimationType type, bool left, bool instant, std::optional<std::string> style) {
            const bool IN  = type == Animation::Workspace::ANIMATION_TYPE_IN;
            const auto MON = ws && !ws->m_isSpecialWorkspace ? ws->m_monitor.lock() : PHLMONITOR{};
            int        to  = 0;
            if (!instant && MON && MON->m_activeWorkspace) {
                to = sc<int>(MON->m_activeWorkspace->m_id);
                if (!IN) {
                    g_switchFrom       = sc<int>(ws->m_id);
                    g_switchFromOffset = ws->m_renderOffset ? ws->m_renderOffset->value() : Vector2D{};
                }
            }
            const int  FROM  = g_switchFrom;
            bool       strip = false;
            if (!instant && ws && decide(ws, type)) {
                instant = true;
                if (IN && MON)
                    DesktopStrip::finishNow();
            } else if (!instant && MON && !scrollOverviewForMonitor(MON) && DesktopStrip::claims(MON, FROM, to, jumpThrough())) {
                instant = true;
                strip   = true;
            }
            rc<origStartAnimation>(g_startAnimHook->m_original)(ws, type, left, instant, style);
            if (IN) {
                if (strip)
                    DesktopStrip::take(MON, FROM, to, g_switchFromOffset, jumpThrough());
                g_switchFrom = 0;
            }
            if (instant || !ws || ws->m_isSpecialWorkspace || !ws->m_renderOffset)
                return;
            if (IN)
                continueFromHere(ws);
        }

        // Focus moving to a window: when its desktop is not the visible one,
        // Hyprland switches to it in here (xdg-activation, the dock, a
        // notification's activation all come through). WORKSPACE_CHANGE is
        // changeWorkspace's own refocus, which runs after the animation started.
        using origFullWindowFocus = void (*)(void*, PHLWINDOW, Desktop::eFocusReason, SP<CWLSurfaceResource>, bool);
        void hkFullWindowFocus(void* thisptr, PHLWINDOW w, Desktop::eFocusReason reason, SP<CWLSurfaceResource> surface, bool forceFSCycle) {
            // A fullscreen game under the window being focused goes to the dock
            // first, still fullscreen (FullscreenGuard.hpp).
            // A hover onto a window only peeking in at the edge, or through the
            // dock, focuses nothing (Mosaic::vetoHoverFocus).
            if (reason == Desktop::FOCUS_REASON_FFM && Mosaic::vetoHoverFocus(w))
                return;
            FullscreenGuard::beforeFocus(w, reason);
            const bool COUNT = reason != Desktop::FOCUS_REASON_WORKSPACE_CHANGE;
            g_focusDepth += COUNT ? 1 : 0;
            rc<origFullWindowFocus>(g_fullFocusHook->m_original)(thisptr, w, reason, surface, forceFSCycle);
            g_focusDepth -= COUNT ? 1 : 0;
        }

        // Focus following the mouse calls rawWindowFocus, not fullWindowFocus:
        // the same veto (Mosaic::vetoHoverFocus).
        using origRawWindowFocus = void (*)(void*, PHLWINDOW, Desktop::eFocusReason, SP<CWLSurfaceResource>);
        void hkRawWindowFocus(void* thisptr, PHLWINDOW w, Desktop::eFocusReason reason, SP<CWLSurfaceResource> surface) {
            if (reason == Desktop::FOCUS_REASON_FFM && Mosaic::vetoHoverFocus(w))
                return;
            rc<origRawWindowFocus>(g_rawFocusHook->m_original)(thisptr, w, reason, surface);
        }

        // `focuswindow` switches the desktop BEFORE it focuses (ConfigActions'
        // focus(): changeWorkspace, then fullWindowFocus), so it is scoped too.
        using origActionsFocus = ::Config::Actions::ActionResult (*)(PHLWINDOW);
        ::Config::Actions::ActionResult hkActionsFocus(PHLWINDOW window) {
            ++g_focusDepth;
            auto result = rc<origActionsFocus>(g_actionFocusHook->m_original)(window);
            --g_focusDepth;
            return result;
        }

        CFunctionHook* hookByMangledName(const std::string& mangled, void* destination) {
            bool found = false;
            auto* hook = FunctionHooks::firstMatch("DesktopSwitch", mangled, destination, {}, &found);
            if (!found) {
                // Not fatal: the switches then animate as Hyprland decides,
                // which is what both toggles' defaults ask for anyway.
                HyprlandAPI::addNotification(HYPRDRIVE_HANDLE, std::format("[hyprdrive] desktop animation toggles unavailable: no {}", mangled),
                                             CHyprColor{1.0, 0.6, 0.2, 1.0}, 5000);
                return nullptr;
            }
            if (hook && !hook->hook())
                return nullptr;
            return hook;
        }
    }

    CFocusScope::CFocusScope() {
        ++g_focusDepth;
    }

    CFocusScope::~CFocusScope() {
        --g_focusDepth;
    }

    namespace {
        // One step on the focused monitor, as a key (classify()'s own-dispatch).
        SDispatchResult step(int dir) {
            const auto MONITOR = Desktop::focusState()->monitor();
            if (!MONITOR || !MONITOR->m_activeWorkspace)
                return {};
            const int CURRENT = sc<int>(MONITOR->m_activeWorkspace->m_id);
            const int TARGET  = DesktopRow::neighbour(rowOn(MONITOR, CURRENT), CURRENT, dir);
            if (TARGET == CURRENT)
                return {};

            ++g_ownDispatch;
            const auto RESULT = ::Config::Actions::changeWorkspace(std::to_string(TARGET));
            --g_ownDispatch;
            if (!RESULT)
                return {.success = false, .error = std::format("desktop: {}", RESULT.error().message)};
            return {};
        }
    }

    SDispatchResult dispatch(std::string arg) {
        if (arg != "next" && arg != "prev")
            return {.success = false, .error = "desktop: expected next or prev"};
        const int  DIR     = arg == "next" ? 1 : -1;
        const auto MONITOR = Desktop::focusState()->monitor();
        if (!MONITOR)
            return {};

        // The overview is up: its desktop card moves, as the wheel moves it there.
        if (const auto OVERVIEW = openScrollOverviewForMonitor(MONITOR)) {
            OVERVIEW->stepDesktop(DIR > 0);
            return {};
        }

        // Fired by a part of a notch: the step waits for the rest of it (the
        // axis listener in init() takes it then).
        if (wheelBindRunning() && !g_notches.take(DIR))
            return {};

        return step(DIR);
    }

    bool overviewWheelSwitchesDesktops(const IPointer::SAxisEvent& e) {
        if (e.source != WL_POINTER_AXIS_SOURCE_WHEEL || e.axis != WL_POINTER_AXIS_VERTICAL_SCROLL || !Config::getScrollDesktops())
            return false;
        if (!g_pInputManager || !g_pKeybindManager)
            return false;
        const auto WANT = g_pKeybindManager->stringToModMask(Config::getScrollDesktopsMods());
        return WANT != 0 && g_pInputManager->getModsFromAllKBs() == WANT;
    }

    void preRender(PHLMONITOR monitor) {
        if (!monitor)
            return;
        // The overview opening owns the desktops: the row lands first.
        if (DesktopStrip::driving(monitor) && scrollOverviewForMonitor(monitor))
            DesktopStrip::finishNow();
        DesktopStrip::preRender(monitor);
    }

    std::string debugReport() {
        return DesktopStrip::debugReport() + " | " + std::format("desktop: scroll_desktops={} mods={} animate keyboard={} focus={} | last switch ws {} cause {} {} | snapped {} left to Hyprland {} | notch bank {} pending {}",
                           Config::getScrollDesktops(), Config::getScrollDesktopsMods(), Config::getAnimateDesktopKeyboard(), Config::getAnimateDesktopFocus(),
                           g_lastWs, causeName(g_lastCause), g_lastSnap ? "snapped" : "left to Hyprland", g_snaps, g_animated, g_notches.accum, g_notches.pending);
    }

    void init() {
        DesktopStrip::init(rowOn, [](const PHLMONITOR&, int id) { (void)::Config::Actions::changeWorkspace(std::to_string(id)); });
        g_startAnimHook = hookByMangledName(
            "_ZN9Animation9Workspace14startAnimationEN9Hyprutils6Memory14CSharedPointerI10CWorkspaceEENS0_14eAnimationTypeEbbSt8optionalINSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEEE",
            rc<void*>(hkStartAnimation));
        g_fullFocusHook = hookByMangledName(
            "_ZN7Desktop11CFocusState15fullWindowFocusEN9Hyprutils6Memory14CSharedPointerINS_4View7CWindowEEENS_12eFocusReasonENS3_I18CWLSurfaceResourceEEb",
            rc<void*>(hkFullWindowFocus));
        g_rawFocusHook = hookByMangledName(
            "_ZN7Desktop11CFocusState14rawWindowFocusEN9Hyprutils6Memory14CSharedPointerINS_4View7CWindowEEENS_12eFocusReasonENS3_I18CWLSurfaceResourceEE",
            rc<void*>(hkRawWindowFocus));
        g_actionFocusHook = hookByMangledName("_ZN6Config7Actions5focusEN9Hyprutils6Memory14CSharedPointerIN7Desktop4View7CWindowEEE", rc<void*>(hkActionsFocus));

        // Every wheel event, ahead of scroll_event_delay's throttle (which only
        // lets the BIND see the first of a burst): the notch bank.
        g_axis = Event::bus()->m_events.input.mouse.axis.listen([](IPointer::SAxisEvent e, Event::SCallbackInfo& info) {
            if (e.source != WL_POINTER_AXIS_SOURCE_WHEEL || e.axis != WL_POINTER_AXIS_VERTICAL_SCROLL)
                return;
            const int V120 = e.deltaDiscrete != 0 ? sc<int>(e.deltaDiscrete) : sc<int>(std::lround(e.delta * 8.0));
            // THE WHEEL MOVES THE ROW (DesktopStrip.hpp; user, 2026-11-02: "if
            // I do two ticks it needs to be able to quickly go through two
            // desktops or more"). On the chord, outside the overview, the wheel
            // is ours and the event goes no further: the bind it would fire is
            // throttled by binds:scroll_event_delay (300 ms), which threw away
            // every notch of a quick burst but the first. Down = next, as the
            // bind.
            if (const auto MONITOR = Desktop::focusState()->monitor();
                !info.cancelled && MONITOR && !openScrollOverviewForMonitor(MONITOR) && overviewWheelSwitchesDesktops(e)) {
                info.cancelled = true;
                if (DesktopStrip::onWheel(MONITOR, V120, stripSettings()))
                    return;
                // A named desktop shown (not in the row): a desktop per notch.
                static int      s_acc  = 0;
                static uint32_t s_last = 0;
                if (e.timeMs < s_last || e.timeMs - s_last > 1000 || (s_acc > 0 && V120 < 0) || (s_acc < 0 && V120 > 0))
                    s_acc = 0;
                s_last = e.timeMs;
                s_acc += V120;
                while (std::abs(s_acc) >= NOTCH) {
                    const int DIR = s_acc > 0 ? 1 : -1;
                    s_acc -= DIR * NOTCH;
                    step(DIR);
                }
                return;
            }
            // The bind fired on part of a notch and this event completes it.
            if (const int DIR = g_notches.feed(V120, e.timeMs); DIR != 0)
                step(DIR);
        });
    }

    void shutdown() {
        DesktopStrip::shutdown();
        g_axis.reset();
        for (auto** hook : {&g_startAnimHook, &g_fullFocusHook, &g_rawFocusHook, &g_actionFocusHook}) {
            if (*hook)
                (*hook)->unhook();
            *hook = nullptr;
        }
        g_ownDispatch = 0;
        g_focusDepth  = 0;
        g_notches.reset();
    }
}
