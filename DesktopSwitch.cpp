// See DesktopSwitch.hpp; the decisions are DesktopSwitchModel.hpp.
#include "DesktopSwitch.hpp"
#include "DesktopSwitchModel.hpp"

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

#include <format>
#include <optional>
#include <string>

namespace ScrollOverview::DesktopSwitch {
    namespace {
        CFunctionHook* g_startAnimHook  = nullptr;
        CFunctionHook* g_fullFocusHook  = nullptr;
        CFunctionHook* g_actionFocusHook = nullptr;

        CHyprSignalListener g_axis;

        // What is running right now. Depths, not flags: a focus call can nest
        // (the dock's activation focuses, and changeWorkspace focuses inside it).
        int g_ownDispatch = 0;
        int g_focusDepth  = 0;

        SNotchAccumulator g_notches;

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

        // ---- hooks
        using origStartAnimation = void (*)(PHLWORKSPACE, Animation::Workspace::eAnimationType, bool, bool, std::optional<std::string>);
        void hkStartAnimation(PHLWORKSPACE ws, Animation::Workspace::eAnimationType type, bool left, bool instant, std::optional<std::string> style) {
            if (!instant && ws && decide(ws, type))
                instant = true;
            rc<origStartAnimation>(g_startAnimHook->m_original)(ws, type, left, instant, style);
        }

        // Focus moving to a window: when its desktop is not the visible one,
        // Hyprland switches to it in here (xdg-activation, the dock, a
        // notification's activation all come through). WORKSPACE_CHANGE is
        // changeWorkspace's own refocus, which runs after the animation started.
        using origFullWindowFocus = void (*)(void*, PHLWINDOW, Desktop::eFocusReason, SP<CWLSurfaceResource>, bool);
        void hkFullWindowFocus(void* thisptr, PHLWINDOW w, Desktop::eFocusReason reason, SP<CWLSurfaceResource> surface, bool forceFSCycle) {
            const bool COUNT = reason != Desktop::FOCUS_REASON_WORKSPACE_CHANGE;
            g_focusDepth += COUNT ? 1 : 0;
            rc<origFullWindowFocus>(g_fullFocusHook->m_original)(thisptr, w, reason, surface, forceFSCycle);
            g_focusDepth -= COUNT ? 1 : 0;
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
            const auto FNS = HyprlandAPI::findFunctionsByName(SCROLLOVERVIEW_HANDLE, mangled);
            if (FNS.empty()) {
                // Not fatal: the switches then animate as Hyprland decides,
                // which is what both toggles' defaults ask for anyway.
                HyprlandAPI::addNotification(SCROLLOVERVIEW_HANDLE, std::format("[hyprdrive] desktop animation toggles unavailable: no {}", mangled),
                                             CHyprColor{1.0, 0.6, 0.2, 1.0}, 5000);
                return nullptr;
            }
            auto* hook = HyprlandAPI::createFunctionHook(SCROLLOVERVIEW_HANDLE, FNS[0].address, destination);
            if (hook && !hook->hook())
                return nullptr;
            return hook;
        }

        std::vector<WORKSPACEID> desktopsOn(const PHLMONITOR& monitor, bool other) {
            std::vector<WORKSPACEID> out;
            for (const auto& REF : State::workspaceState()->workspaces()) {
                const auto WS = REF.lock();
                if (!WS || WS->m_isSpecialWorkspace || WS->m_id < 1)
                    continue;
                if ((WS->m_monitor.lock() == monitor) != other)
                    out.push_back(WS->m_id);
            }
            return out;
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
            // A Mosaic desktop on its infinite canvas: the wheel walks the
            // canvas first, and the desktops only from either end of it.
            if (!MONITOR->m_activeSpecialWorkspace && Mosaic::canvasStep(MONITOR->m_activeWorkspace, dir))
                return {};
            const auto  HERE    = desktopsOn(MONITOR, false);
            const auto  THERE   = desktopsOn(MONITOR, true);
            WORKSPACEID highest = 0;
            for (const auto ID : HERE)
                highest = std::max(highest, ID);
            const auto CURRENT = MONITOR->m_activeWorkspace->m_id;
            const auto TARGET  = stepTarget(CURRENT, dir, std::max(highest, CURRENT), [&](int64_t id) { return std::ranges::find(THERE, id) != THERE.end(); });
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

    std::string debugReport() {
        return std::format("desktop: scroll_desktops={} mods={} animate keyboard={} focus={} | last switch ws {} cause {} {} | snapped {} left to Hyprland {} | notch bank {} pending {}",
                           Config::getScrollDesktops(), Config::getScrollDesktopsMods(), Config::getAnimateDesktopKeyboard(), Config::getAnimateDesktopFocus(),
                           g_lastWs, causeName(g_lastCause), g_lastSnap ? "snapped" : "left to Hyprland", g_snaps, g_animated, g_notches.accum, g_notches.pending);
    }

    void init() {
        g_startAnimHook = hookByMangledName(
            "_ZN9Animation9Workspace14startAnimationEN9Hyprutils6Memory14CSharedPointerI10CWorkspaceEENS0_14eAnimationTypeEbbSt8optionalINSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEEE",
            rc<void*>(hkStartAnimation));
        g_fullFocusHook = hookByMangledName(
            "_ZN7Desktop11CFocusState15fullWindowFocusEN9Hyprutils6Memory14CSharedPointerINS_4View7CWindowEEENS_12eFocusReasonENS3_I18CWLSurfaceResourceEEb",
            rc<void*>(hkFullWindowFocus));
        g_actionFocusHook = hookByMangledName("_ZN6Config7Actions5focusEN9Hyprutils6Memory14CSharedPointerIN7Desktop4View7CWindowEEE", rc<void*>(hkActionsFocus));

        // Every wheel event, ahead of scroll_event_delay's throttle (which only
        // lets the BIND see the first of a burst): the notch bank.
        g_axis = Event::bus()->m_events.input.mouse.axis.listen([](IPointer::SAxisEvent e, Event::SCallbackInfo&) {
            if (e.source != WL_POINTER_AXIS_SOURCE_WHEEL || e.axis != WL_POINTER_AXIS_VERTICAL_SCROLL)
                return;
            const int V120 = e.deltaDiscrete != 0 ? sc<int>(e.deltaDiscrete) : sc<int>(std::lround(e.delta * 8.0));
            // The bind fired on part of a notch and this event completes it.
            if (const int DIR = g_notches.feed(V120, e.timeMs); DIR != 0)
                step(DIR);
        });
    }

    void shutdown() {
        g_axis.reset();
        for (auto** hook : {&g_startAnimHook, &g_fullFocusHook, &g_actionFocusHook}) {
            if (*hook)
                (*hook)->unhook();
            *hook = nullptr;
        }
        g_ownDispatch = 0;
        g_focusDepth  = 0;
        g_notches.reset();
    }
}
