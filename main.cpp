#define WLR_USE_UNSTABLE

#include <unistd.h>

#include <algorithm>

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/config/ConfigManager.hpp>
#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/devices/IKeyboard.hpp>
#include <hyprland/src/devices/IPointer.hpp>
#include <xkbcommon/xkbcommon.h>
#include <hyprland/src/managers/input/trackpad/GestureTypes.hpp>
#include <hyprland/src/managers/input/trackpad/TrackpadGestures.hpp>

#include <hyprutils/string/ConstVarList.hpp>
using namespace Hyprutils::String;

#include "globals.hpp"
#include "Config.hpp"
#include "Dock.hpp"
#include "LauncherEntry.hpp"
#include "Minimize.hpp"
#include "PluginVersion.hpp"
#include "scrollOverview.hpp"
#include "OverviewGesture.hpp"
#include "SearchProviders.hpp"

// Methods
static CFunctionHook* g_pScrollRenderWorkspaceHook = nullptr;
static CFunctionHook* g_pScrollAddDamageHookA      = nullptr;
static CFunctionHook* g_pScrollAddDamageHookB      = nullptr;
static CFunctionHook* g_pScrollDamageSurfaceHook   = nullptr;
static CFunctionHook* g_pScrollScheduleFrameHook   = nullptr;
static CFunctionHook* g_pScrollSendFrameEventsHook = nullptr;
static CFunctionHook* g_pScrollSurfaceFrameHook    = nullptr;
static CFunctionHook* g_pScrollMouseMovedHook      = nullptr;
typedef void (*origRenderWorkspace)(void*, PHLMONITOR, PHLWORKSPACE, const Time::steady_tp&, const CBox&);
typedef void (*origAddDamageA)(void*, const CBox&);
typedef void (*origAddDamageB)(void*, const pixman_region32_t*);
typedef void (*origDamageSurface)(void*, SP<CWLSurfaceResource>, double, double, double);
typedef void (*origScheduleFrame)(void*, Aquamarine::IOutput::scheduleFrameReason);
typedef void (*origSendFrameEventsToWorkspace)(void*, PHLMONITOR, PHLWORKSPACE, const Time::steady_tp&);
typedef void (*origSurfaceFrame)(void*, const Time::steady_tp&);
typedef void (*origOnMouseMoved)(void*, IPointer::SMotionEvent);

static bool g_unloading = false;

// Do NOT change this function.
APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

static bool renderingOverview = false;
static bool damageFromSurface = false;
static PHLMONITORREF renderingOverviewMonitor;
static bool g_scrollOverviewHooksActive = false;

static void failNotif(const std::string& reason);

bool ensureScrollOverviewHooks() {
    if (g_scrollOverviewHooksActive)
        return true;

    bool success = g_pScrollRenderWorkspaceHook->hook();
    success      = success && g_pScrollScheduleFrameHook->hook();
    success      = success && g_pScrollDamageSurfaceHook->hook();
    success      = success && g_pScrollSendFrameEventsHook->hook();
    success      = success && g_pScrollSurfaceFrameHook->hook();
    success      = success && g_pScrollAddDamageHookA->hook();
    success      = success && g_pScrollAddDamageHookB->hook();

    if (!success) {
        disableScrollOverviewHooks();
        failNotif("Failed enabling overview hooks (is other overview plugin enabled?)");
        return false;
    }

    g_scrollOverviewHooksActive = true;
    return true;
}

void disableScrollOverviewHooks() {
    if (g_pScrollAddDamageHookB)
        g_pScrollAddDamageHookB->unhook();
    if (g_pScrollAddDamageHookA)
        g_pScrollAddDamageHookA->unhook();
    if (g_pScrollSurfaceFrameHook)
        g_pScrollSurfaceFrameHook->unhook();
    if (g_pScrollSendFrameEventsHook)
        g_pScrollSendFrameEventsHook->unhook();
    if (g_pScrollDamageSurfaceHook)
        g_pScrollDamageSurfaceHook->unhook();
    if (g_pScrollScheduleFrameHook)
        g_pScrollScheduleFrameHook->unhook();
    if (g_pScrollRenderWorkspaceHook)
        g_pScrollRenderWorkspaceHook->unhook();

    g_scrollOverviewHooksActive = false;
}

// X30. The autohide barrier needs the RELATIVE motion, which only this call
// carries: the bus's mouse.move gives the absolute position, and at the bottom
// edge the cursor is clamped, so the position stops changing while the user is
// still pushing. Fed AFTER the original, so the position the barrier tests
// against is the one this motion produced.
static void hkOnMouseMoved(void* thisptr, IPointer::SMotionEvent e) {
    rc<origOnMouseMoved>(g_pScrollMouseMovedHook->m_original)(thisptr, e);
    ScrollOverview::Dock::feedPointerMotion(e.delta);
}

static void hkScheduleFrame(void* thisptr, Aquamarine::IOutput::scheduleFrameReason reason) {
    const auto OVERVIEW = scrollOverviewForMonitor(sc<Monitor::CMonitor*>(thisptr)->m_self.lock());
    if (OVERVIEW) {
        using enum Aquamarine::IOutput::scheduleFrameReason;

        const bool THROTTLEDREASON =
            reason == AQ_SCHEDULE_UNKNOWN || reason == AQ_SCHEDULE_CLIENT_UNKNOWN || reason == AQ_SCHEDULE_NEEDS_FRAME || reason == AQ_SCHEDULE_RENDER_MONITOR ||
            reason == AQ_SCHEDULE_DAMAGE;

        if (THROTTLEDREASON && !OVERVIEW->blockDamageReporting && !OVERVIEW->shouldAllowRealtimePreviewSchedule())
            return;
    }

    rc<origScheduleFrame>(g_pScrollScheduleFrameHook->m_original)(thisptr, reason);
}

//
static void hkRenderWorkspace(void* thisptr, PHLMONITOR pMonitor, PHLWORKSPACE pWorkspace, const Time::steady_tp& now, const CBox& geometry) {
    const auto OVERVIEW = scrollOverviewForMonitor(pMonitor);
    if (!OVERVIEW || renderingOverview)
        rc<origRenderWorkspace>(g_pScrollRenderWorkspaceHook->m_original)(thisptr, pMonitor, pWorkspace, now, geometry);
    else {
        const bool PREVRENDERINGOVERVIEW = renderingOverview;
        const auto PREVRENDERINGMONITOR  = renderingOverviewMonitor;
        const auto PREVOVERVIEW          = g_pScrollOverview;
        renderingOverview                = true;
        renderingOverviewMonitor         = pMonitor;
        g_pScrollOverview                = OVERVIEW;
        OVERVIEW->render();
        g_pScrollOverview = PREVOVERVIEW;
        renderingOverviewMonitor = PREVRENDERINGMONITOR;
        renderingOverview = PREVRENDERINGOVERVIEW;
    }
}

static void hkDamageSurface(void* thisptr, SP<CWLSurfaceResource> surface, double x, double y, double scale) {
    const bool HANDLED = scrollOverviews().empty() ||
        std::ranges::any_of(scrollOverviews(), [](const auto& overview) { return overview && overview->blockDamageReporting; }) ||
        std::ranges::all_of(scrollOverviews(), [&surface](const auto& overview) { return !overview || overview->shouldHandleSurfaceDamage(surface); });
    if (HANDLED) {
        const bool PREVDAMAGEFROMSURFACE = damageFromSurface;
        damageFromSurface                = !scrollOverviews().empty();
        rc<origDamageSurface>(g_pScrollDamageSurfaceHook->m_original)(thisptr, surface, x, y, scale);
        damageFromSurface = PREVDAMAGEFROMSURFACE;
    }
}

static void hkSendFrameEventsToWorkspace(void* thisptr, PHLMONITOR monitor, PHLWORKSPACE workspace, const Time::steady_tp& now) {
    if (scrollOverviewForMonitor(monitor))
        return;

    rc<origSendFrameEventsToWorkspace>(g_pScrollSendFrameEventsHook->m_original)(thisptr, monitor, workspace, now);
}

static void hkSurfaceFrame(void* thisptr, const Time::steady_tp& now) {
    const auto SURFACE = sc<CWLSurfaceResource*>(thisptr)->m_self.lock();

    if (std::ranges::any_of(scrollOverviews(), [&SURFACE, &now](const auto& overview) { return overview && !overview->shouldAllowSurfaceFrame(SURFACE, now); }))
        return;

    rc<origSurfaceFrame>(g_pScrollSurfaceFrameHook->m_original)(thisptr, now);
}

static void hkAddDamageA(void* thisptr, const CBox& box) {
    const auto PMONITOR = sc<Monitor::CMonitor*>( thisptr );
    const auto OVERVIEW = scrollOverviewForMonitor(PMONITOR->m_self.lock());

    if (OVERVIEW && renderingOverviewMonitor.lock() == PMONITOR->m_self.lock() && !damageFromSurface && OVERVIEW->shouldSuppressRenderDamage()) {
        return;
    }

    if (!OVERVIEW || OVERVIEW->blockDamageReporting || damageFromSurface) {
        rc<origAddDamageA>(g_pScrollAddDamageHookA->m_original)(thisptr, box);
        return;
    }

    OVERVIEW->onDamageReported();
    rc<origAddDamageA>(g_pScrollAddDamageHookA->m_original)(thisptr, box);
}

static void hkAddDamageB(void* thisptr, const pixman_region32_t* rg) {
    const auto PMONITOR = sc<Monitor::CMonitor*>(thisptr);
    const auto OVERVIEW = scrollOverviewForMonitor(PMONITOR->m_self.lock());

    if (OVERVIEW && renderingOverviewMonitor.lock() == PMONITOR->m_self.lock() && !damageFromSurface && OVERVIEW->shouldSuppressRenderDamage()) {
        return;
    }

    if (!OVERVIEW || OVERVIEW->blockDamageReporting || damageFromSurface) {
        rc<origAddDamageB>(g_pScrollAddDamageHookB->m_original)(thisptr, rg);
        return;
    }

    OVERVIEW->onDamageReported();
    rc<origAddDamageB>(g_pScrollAddDamageHookB->m_original)(thisptr, rg);
}

static std::pair<std::string, std::string> splitOverviewArg(const std::string& arg) {
    const auto FIRST = arg.find_first_not_of(" \t");
    if (FIRST == std::string::npos)
        return {"on", ""};

    const auto SEPARATOR = arg.find_first_of(" \t", FIRST);
    if (SEPARATOR == std::string::npos)
        return {arg.substr(FIRST), ""};

    const auto TARGET = arg.find_first_not_of(" \t", SEPARATOR);
    if (TARGET == std::string::npos)
        return {arg.substr(FIRST, SEPARATOR - FIRST), ""};

    const auto LAST = arg.find_last_not_of(" \t");
    return {arg.substr(FIRST, SEPARATOR - FIRST), arg.substr(TARGET, LAST - TARGET + 1)};
}

static std::vector<PHLMONITOR> overviewTargetMonitors(const std::string& target) {
    if (target == "all")
        return State::monitorState()->monitors();

    if (!target.empty()) {
        const auto& MONITORS = State::monitorState()->monitors();
        const auto  IT       = std::ranges::find_if(MONITORS, [&target](const auto& monitor) { return monitor && monitor->m_name == target; });
        return IT == MONITORS.end() ? std::vector<PHLMONITOR>{} : std::vector<PHLMONITOR>{*IT};
    }

    const auto MONITOR = Desktop::focusState()->monitor();
    return MONITOR ? std::vector<PHLMONITOR>{MONITOR} : std::vector<PHLMONITOR>{};
}

static bool openOverview(PHLMONITOR monitor) {
    if (!monitor || scrollOverviewForMonitor(monitor))
        return true;

    if (!ensureScrollOverviewHooks())
        return false;

    const bool PREVRENDERINGOVERVIEW = renderingOverview;
    renderingOverview                = true;
    auto overview                    = makeShared<CScrollOverview>(monitor->m_activeWorkspace, false, monitor);
    registerScrollOverview(overview);
    renderingOverview = PREVRENDERINGOVERVIEW;
    return true;
}

// X32. The dock's Show Applications button opens the overview, and the hook
// setup above is not something a second implementation should duplicate.
bool openScrollOverview(PHLMONITOR monitor) {
    return openOverview(monitor);
}

static SDispatchResult onOverviewDispatcher(std::string arg) {
    g_overviewSearch.clear(); // every open starts unfiltered
    SearchProviders::query("");
    g_overviewAppSelection = -1;
    const auto [ACTION, TARGET] = splitOverviewArg(arg);
    const auto ACTIVE           = activeScrollOverview();

    if (ACTIVE && ACTIVE->m_isSwiping)
        return {.success = false, .error = "already swiping"};

    if (ACTION == "select") {
        if (ACTIVE)
            ACTIVE->selectHoveredWorkspace();
        return {};
    }

    if (ACTION == "off" || ACTION == "close" || ACTION == "disable") {
        if (TARGET.empty() || TARGET == "all") {
            const auto OPEN = scrollOverviews();
            for (const auto& overview : OPEN) {
                if (overview)
                    overview->close();
            }
            return {};
        }

        const auto MONITORS = overviewTargetMonitors(TARGET);
        if (MONITORS.empty())
            return {.success = false, .error = "monitor not found: " + TARGET};
        if (const auto overview = scrollOverviewForMonitor(MONITORS.front()))
            overview->close();
        return {};
    }

    if (ACTION != "toggle" && ACTION != "on" && ACTION != "open" && ACTION != "enable")
        return {.success = false, .error = "invalid arg. expected toggle|open|close|select [monitor|all]"};

    const auto MONITORS = overviewTargetMonitors(TARGET);
    if (MONITORS.empty())
        return {.success = false, .error = TARGET.empty() ? "no active monitor" : "monitor not found: " + TARGET};

    const bool ALL_OPEN = std::ranges::all_of(MONITORS, [](const auto& monitor) { return !!scrollOverviewForMonitor(monitor); });
    if (ACTION == "toggle" && ALL_OPEN) {
        for (const auto& monitor : MONITORS) {
            if (const auto overview = scrollOverviewForMonitor(monitor))
                overview->close();
        }
        return {};
    }

    for (const auto& monitor : MONITORS) {
        if (!openOverview(monitor))
            return {.success = false, .error = "failed enabling overview hooks (is other overview plugin enabled?)"};
    }
    return {};
}

// Tap-SUPER toggles the overview.
//
// This cannot live in a Lua bind: measured on 0.56.1, every bind form on
// SUPER_L fires identically whether SUPER was tapped alone or held as a
// modifier for another key, so a bind would open the overview on every
// SUPER+<key> shortcut. The tap/hold distinction only exists at the raw key
// event level.
// ponytail: raw evdev keycodes; a remapped SUPER will not be recognised.
static constexpr uint32_t EVDEV_KEY_LEFTMETA  = 125;
static constexpr uint32_t EVDEV_KEY_RIGHTMETA = 126;

// Only a real key cancels the tap. Modifier and lock keycodes must be ignored:
// this compositor emits a synthetic CAPSLOCK (58) press/release pair around
// every key event, which would otherwise cancel every tap before it completed.
static bool isModifierKeycode(uint32_t keycode) {
    switch (keycode) {
        case 29:  // LEFTCTRL
        case 42:  // LEFTSHIFT
        case 54:  // RIGHTSHIFT
        case 56:  // LEFTALT
        case 58:  // CAPSLOCK
        case 69:  // NUMLOCK
        case 70:  // SCROLLLOCK
        case 97:  // RIGHTCTRL
        case 100: // RIGHTALT
        case EVDEV_KEY_LEFTMETA:
        case EVDEV_KEY_RIGHTMETA: return true;
        default: return false;
    }
}

static constexpr uint32_t EVDEV_KEY_ESC       = 1;
static constexpr uint32_t EVDEV_KEY_BACKSPACE = 14;

static xkb_state* activeXkbState() {
    const auto KEEB = g_pSeatManager ? g_pSeatManager->m_keyboard.lock() : nullptr;
    return KEEB ? KEEB->m_xkbState : nullptr;
}

// SUPER, CTRL and ALT must keep their chords working while the overview is
// open, so a key pressed with one of them held is never search input.
//
// Tracked from the raw key stream rather than read from xkb: xkb was measured
// reporting logo=0 for the Z press of a SUPER+Z chord in this VM (see
// share/f_guard_fix.py). Shift is deliberately absent -- it types.
static bool isGuardModifierKeycode(uint32_t keycode) {
    switch (keycode) {
        case 29:  // LEFTCTRL
        case 56:  // LEFTALT
        case 97:  // RIGHTCTRL
        case 100: // RIGHTALT
        case EVDEV_KEY_LEFTMETA:
        case EVDEV_KEY_RIGHTMETA: return true;
        default: return false;
    }
}

static int g_heldGuardModifiers = 0;

// The character this keycode would type, or 0 if it types nothing. Returns 0
// whenever a guard modifier is held so SUPER+Q stays a keybind instead of
// becoming the letter q.
static char searchCharFor(uint32_t keycode) {
    if (g_heldGuardModifiers > 0)
        return 0;

    const auto STATE = activeXkbState();
    if (!STATE)
        return 0;

    char buf[8] = {};
    // ponytail: ASCII only. Anything wider is an input-method problem, not a
    // filter problem; revisit if the rice ever needs non-Latin search.
    if (xkb_state_key_get_utf8(STATE, keycode + 8, buf, sizeof(buf)) != 1)
        return 0;

    return buf[0] >= 0x20 && buf[0] < 0x7F ? buf[0] : 0;
}

// OVERVIEW_CPP_SPEC §5 F5. The overview is not a wayland client and takes no
// keyboard focus, so the query is assembled from the raw key stream and those
// events are cancelled to keep them out of the focused window underneath.
// Decided from keycode and modifier state alone so a press and its release
// always agree, and no half-consumed key leaks a stray release downstream.
static bool isSearchKey(uint32_t keycode) {
    if (!activeScrollOverview())
        return false;

    // X5: ESC is always ours while the overview is open -- it either clears the
    // query or exits -- so it must never fall through to the window underneath.
    if (keycode == EVDEV_KEY_ESC)
        return true;

    if (keycode == EVDEV_KEY_BACKSPACE)
        return !g_overviewSearch.empty();

    return searchCharFor(keycode) != 0;
}

static void applySearchKey(uint32_t keycode) {
    // X5, GNOME-style: the first ESC drops the filter, the next one leaves.
    if (keycode == EVDEV_KEY_ESC) {
        if (g_overviewSearch.empty()) {
            for (const auto& overview : scrollOverviews())
                if (overview)
                    overview->close();
            return;
        }
        g_overviewSearch.clear();
    }
    else if (keycode == EVDEV_KEY_BACKSPACE)
        g_overviewSearch.pop_back();
    else if (const char C = searchCharFor(keycode); C != 0)
        g_overviewSearch.push_back(C);

    // X20: every keystroke starts a new provider generation. Non-blocking, so
    // this costs the keystroke nothing; results land over the next frames.
    SearchProviders::query(g_overviewSearch);

    // The ranking changes under any edit, so a held index would point at a
    // different app than the one the user saw highlighted.
    g_overviewAppSelection = -1;

    for (const auto& overview : scrollOverviews())
        if (overview)
            overview->damage();
}

static CHyprSignalListener g_pTapSuperKeyHook;
static CHyprSignalListener g_pTapSuperButtonHook;
static bool                g_tapSuperCandidate = false;
static uint32_t            g_tapSuperPressedAt = 0;

static void                registerTapSuper() {
    g_pTapSuperKeyHook = Event::bus()->m_events.input.keyboard.key.listen([](IKeyboard::SKeyEvent event, Event::SCallbackInfo& info) {
        const bool PRESSED = event.state == WL_KEYBOARD_KEY_STATE_PRESSED;
        const bool ISSUPER = event.keycode == EVDEV_KEY_LEFTMETA || event.keycode == EVDEV_KEY_RIGHTMETA;

        if (isGuardModifierKeycode(event.keycode)) {
            // Clamped, not just decremented: a modifier released while its
            // press went to someone else would otherwise strand the count
            // negative and disable search for the rest of the session.
            g_heldGuardModifiers = std::max(0, g_heldGuardModifiers + (PRESSED ? 1 : -1));
        }

        if (!ISSUPER && isSearchKey(event.keycode)) {
            info.cancelled = true;
            if (PRESSED)
                applySearchKey(event.keycode);
            return;
        }

        if (!ISSUPER) {
            if (PRESSED && !isModifierKeycode(event.keycode))
                g_tapSuperCandidate = false; // SUPER is being held as a modifier
            return;
        }

        if (PRESSED) {
            g_tapSuperCandidate = true;
            g_tapSuperPressedAt = event.timeMs;
            return;
        }

        if (!g_tapSuperCandidate)
            return;
        g_tapSuperCandidate = false;

        if (!ScrollOverview::Config::getTapSuper())
            return;

        const auto TIMEOUT = ScrollOverview::Config::getTapSuperTimeoutMs();
        if (TIMEOUT > 0 && event.timeMs - g_tapSuperPressedAt > static_cast<uint32_t>(TIMEOUT))
            return;

        onOverviewDispatcher("toggle all");
    });

    // SUPER+click/drag (move or resize a window) must not count as a tap.
    g_pTapSuperButtonHook = Event::bus()->m_events.input.mouse.button.listen([](IPointer::SButtonEvent event, Event::SCallbackInfo& info) { g_tapSuperCandidate = false; });
}

static SDispatchResult onNavigateDispatcher(std::string arg) {
    const auto OVERVIEW = activeScrollOverview();
    if (!OVERVIEW)
        return {};

    if (arg != "left" && arg != "right" && arg != "up" && arg != "down")
        return {.success = false, .error = "invalid arg. expected left|right|up|down"};

    OVERVIEW->moveSelection(arg);
    return {};
}

static SDispatchResult onWindowDispatcher(std::string arg) {
    const auto OVERVIEW = activeScrollOverview();
    if (!OVERVIEW)
        return {};

    if (arg == "click") {
        OVERVIEW->performPrimaryClickAction();
        return {};
    }

    if (arg != "select" && arg != "close")
        return {.success = false, .error = "invalid arg. expected select|close|click"};

    OVERVIEW->windowDispatcherAction(arg);
    return {};
}

static void failNotif(const std::string& reason) {
    HyprlandAPI::addNotification(SCROLLOVERVIEW_HANDLE, "[scrolloverview] Failure in initialization: " + reason, CHyprColor{1.0, 0.2, 0.2, 1.0}, 5000);
}

// Helper function to find a function by name and ensure it contains one of the requested substrings in its demangled name (to disambiguate overloads).
static void* findFnOrThrow(const std::string& name, std::initializer_list<std::string_view> demangledNeedles) {
    auto fns = HyprlandAPI::findFunctionsByName(SCROLLOVERVIEW_HANDLE, name);
    if (fns.empty()) {
        failNotif(std::format("no fns for hook {}", name));
        throw std::runtime_error(std::format("[scrolloverview] No fns for hook {}", name));
    }

    if (demangledNeedles.size() == 0 || (demangledNeedles.size() == 1 && demangledNeedles.begin()->empty()))
        return fns[0].address;

    std::vector<SFunctionMatch> matches;
    matches.reserve(fns.size());
    for (const auto& fn : fns) {
        for (const auto& needle : demangledNeedles) {
            if (needle.empty() || fn.demangled.find(needle) != std::string::npos) {
                matches.push_back(fn);
                break;
            }
        }
    }

    if (matches.empty()) {
        failNotif(std::format("no matching overload for hook {}", name));
        throw std::runtime_error(std::format("[scrolloverview] No matching overload for hook {}", name));
    }

    if (matches.size() > 1) {
        failNotif(std::format("ambiguous overload for hook {} ({} matches)", name, matches.size()));
        throw std::runtime_error(std::format("[scrolloverview] Ambiguous overload for hook {}", name));
    }

    return matches[0].address;
}

// shared core: register / unregister the overview trackpad gesture. used by both the hyprlang
// keyword and the Lua `scrolloverview.gesture` function so both configure the same gesture system.
static std::expected<void, std::string> applyOverviewGesture(size_t fingerCount, eTrackpadGestureDirection direction, const std::string& action, uint32_t modMask,
                                                             float deltaScale, bool disableInhibit) {
    if (fingerCount <= 1 || fingerCount >= 10)
        return std::unexpected(std::format("Invalid value {} for finger count", fingerCount));

    if (direction == TRACKPAD_GESTURE_DIR_NONE)
        return std::unexpected("Invalid direction");

    if (action == "overview")
        return g_pTrackpadGestures->addGesture(makeUnique<COverviewGesture>(), fingerCount, direction, modMask, deltaScale, disableInhibit);

    if (action == "unset")
        return g_pTrackpadGestures->removeGesture(fingerCount, direction, modMask, deltaScale, disableInhibit);

    return std::unexpected(std::format("Invalid gesture: {}", action));
}

// Lua-facing registrar (scrolloverview.gesture). takes the direction/mods as strings and resolves
// them the same way the keyword does, then defers to applyOverviewGesture.
static SDispatchResult onRegisterOverviewGesture(size_t fingerCount, const std::string& directionStr, const std::string& action, const std::string& mods, float deltaScale,
                                                 bool disableInhibit) {
    if (g_unloading)
        return {};

    const auto direction = g_pTrackpadGestures->dirForString(directionStr);
    if (direction == TRACKPAD_GESTURE_DIR_NONE)
        return {.success = false, .error = std::format("Invalid direction: {}", directionStr)};

    uint32_t modMask = 0;
    if (!mods.empty() && g_pKeybindManager)
        modMask = g_pKeybindManager->stringToModMask(mods);

    const auto res = applyOverviewGesture(fingerCount, direction, action, modMask, std::clamp(deltaScale, 0.1F, 10.F), disableInhibit);
    if (!res)
        return {.success = false, .error = res.error()};

    return {};
}

static Hyprlang::CParseResult overviewGestureKeyword(const char* LHS, const char* RHS) {
    Hyprlang::CParseResult result;

    if (g_unloading)
        return result;

    CConstVarList             data(RHS);

    size_t                    fingerCount = 0;

    try {
        fingerCount = std::stoul(std::string{data[0]});
    } catch (...) {
        result.setError(std::format("Invalid value {} for finger count", data[0]).c_str());
        return result;
    }

    const auto direction = g_pTrackpadGestures->dirForString(data[1]);

    if (direction == TRACKPAD_GESTURE_DIR_NONE) {
        result.setError(std::format("Invalid direction: {}", data[1]).c_str());
        return result;
    }

    int      startDataIdx   = 2;
    uint32_t modMask        = 0;
    float    deltaScale     = 1.F;
    bool     disableInhibit = false;

    while (true) {

        if (data[startDataIdx].starts_with("mod:")) {
            modMask = g_pKeybindManager->stringToModMask(std::string{data[startDataIdx].substr(4)});
            startDataIdx++;
            continue;
        } else if (data[startDataIdx].starts_with("scale:")) {
            try {
                deltaScale = std::clamp(std::stof(std::string{data[startDataIdx].substr(6)}), 0.1F, 10.F);
                startDataIdx++;
                continue;
            } catch (...) {
                result.setError(std::format("Invalid delta scale: {}", std::string{data[startDataIdx].substr(6)}).c_str());
                return result;
            }
        } else if (data[startDataIdx] == "disable_inhibit") {
            disableInhibit = true;
            startDataIdx++;
            continue;
        }

        break;
    }

    const auto resultFromGesture = applyOverviewGesture(fingerCount, direction, std::string{data[startDataIdx]}, modMask, deltaScale, disableInhibit);

    if (!resultFromGesture)
        result.setError(resultFromGesture.error().c_str());

    return result;
}

// OVERVIEW_CPP_SPEC §13.9 X24. hyprgnomedock does not exist yet, so this is how
// the minimize engine is driven and tested until its icons can call it.
static SDispatchResult onMinimizeDispatcher(std::string arg) {
    if (arg == "restore") {
        const auto MINIMIZED = ScrollOverview::Minimize::minimized();
        if (MINIMIZED.empty())
            return {.success = false, .error = "nothing is minimized"};

        if (!ScrollOverview::Minimize::restore(MINIMIZED.back()))
            return {.success = false, .error = "restore failed"};

        return {};
    }

    const auto WINDOW = Desktop::focusState()->window();
    if (!WINDOW)
        return {.success = false, .error = "no focused window"};

    if (!ScrollOverview::Minimize::minimize(WINDOW))
        return {.success = false, .error = "window cannot be minimized"};

    return {};
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    SCROLLOVERVIEW_HANDLE = handle;

    const std::string HASH        = __hyprland_api_get_hash();
    const std::string CLIENT_HASH = __hyprland_api_get_client_hash();

    if (HASH != CLIENT_HASH) {
        failNotif("Version mismatch (headers ver is not equal to running hyprland ver)");
        throw std::runtime_error("[he] Version mismatch");
    }

    g_pScrollRenderWorkspaceHook = HyprlandAPI::createFunctionHook(
        SCROLLOVERVIEW_HANDLE,
        findFnOrThrow("renderWorkspace", {"CHyprRenderer::renderWorkspace(", "IHyprRenderer::renderWorkspace("}),
        rc<void*>(hkRenderWorkspace));

    g_pScrollScheduleFrameHook = HyprlandAPI::createFunctionHook(
        SCROLLOVERVIEW_HANDLE, 
        findFnOrThrow("_ZN7Monitor8CMonitor13scheduleFrameEN10Aquamarine7IOutput19scheduleFrameReasonE", {""}),
        rc<void*>(hkScheduleFrame));

    g_pScrollDamageSurfaceHook = HyprlandAPI::createFunctionHook(
        SCROLLOVERVIEW_HANDLE,
        findFnOrThrow("damageSurface", {"CHyprRenderer::damageSurface(", "IHyprRenderer::damageSurface("}),
        rc<void*>(hkDamageSurface));

    g_pScrollSendFrameEventsHook = HyprlandAPI::createFunctionHook(
        SCROLLOVERVIEW_HANDLE,
        findFnOrThrow("sendFrameEventsToWorkspace", {"CHyprRenderer::sendFrameEventsToWorkspace(", "IHyprRenderer::sendFrameEventsToWorkspace("}),
        rc<void*>(hkSendFrameEventsToWorkspace));

    g_pScrollSurfaceFrameHook = HyprlandAPI::createFunctionHook(
        SCROLLOVERVIEW_HANDLE,
        findFnOrThrow("_ZN18CWLSurfaceResource5frameERKNSt6chrono10time_pointINS0_3_V212steady_clockENS0_8durationIlSt5ratioILl1ELl1000000000EEEEEE", {""}),
        rc<void*>(hkSurfaceFrame));

    g_pScrollAddDamageHookB = HyprlandAPI::createFunctionHook(
        SCROLLOVERVIEW_HANDLE,
        findFnOrThrow("addDamageEPK15pixman_region32", {"CMonitor::addDamage"}),
        rc<void*>(hkAddDamageB));

    g_pScrollAddDamageHookA = HyprlandAPI::createFunctionHook(
        SCROLLOVERVIEW_HANDLE,
        findFnOrThrow("_ZN7Monitor8CMonitor9addDamageERKN9Hyprutils4Math4CBoxE", {""}),
        rc<void*>(hkAddDamageA));

    // X30. Hooked HERE and not through ensureScrollOverviewHooks(): those go on
    // and off with the overview, and the autohide barrier lives on the plain
    // desktop, which is exactly where they are not installed.
    g_pScrollMouseMovedHook = HyprlandAPI::createFunctionHook(
        SCROLLOVERVIEW_HANDLE,
        findFnOrThrow("onMouseMoved", {"CInputManager::onMouseMoved("}),
        rc<void*>(hkOnMouseMoved));
    g_pScrollMouseMovedHook->hook();

    static auto P = Event::bus()->m_events.render.pre.listen([](PHLMONITOR monitor) {
        if (const auto overview = scrollOverviewForMonitor(monitor))
            overview->onPreRender();

        ScrollOverview::Dock::damageIfChanged(monitor);
    });

    // X27. NOT the renderWorkspace hook: that one is installed on demand by
    // ensureScrollOverviewHooks() and dropped again by removeOverview(), so it
    // does not exist on a plain desktop -- which is exactly where a dock lives.
    // POST_WINDOWS also puts the dock above windows and below the bar's top
    // layer.
    //
    // §10 clause 6, pinned-in-overview: this stage fires far below the overview's
    // own pass, so the pill was buried under it. The overview now draws the dock
    // itself at the end of its render, and this hook stands down for that monitor
    // -- otherwise the pill is drawn twice and its translucent background blends
    // over itself.
    // The dock's hover highlight on a PLAIN desktop. render.pre only fires when a
    // frame is already happening, so on an idle desktop a pointer move over the
    // pill damages nothing and the highlight never appears. The overview has its
    // own mouse hook and calls this from there.
    // X30. Flipping dock-fixed at runtime damages nothing by itself: with the
    // pointer still and no window repainting, there is no frame for the dock to
    // be drawn into and the change would not show until something else moved.
    static auto DOCKCONFIG = Event::bus()->m_events.config.reloaded.listen([] {
        for (const auto& MONITOR : State::monitorState()->monitors())
            ScrollOverview::Dock::damageIfChanged(MONITOR);
    });

    static auto DOCKHOVER = Event::bus()->m_events.input.mouse.move.listen([](Vector2D, Event::SCallbackInfo&) {
        const auto POINT = g_pInputManager->getMouseCoordsInternal();
        for (const auto& MONITOR : State::monitorState()->monitors()) {
            if (!MONITOR || scrollOverviewForMonitor(MONITOR) || !MONITOR->logicalBox().containsPoint(POINT))
                continue;

            // X32. The desktop dock reorders too, and its drag needs motion for
            // the same reason the highlight does: on an idle desktop nothing
            // else is asking for a frame.
            if (ScrollOverview::Dock::dragPending())
                ScrollOverview::Dock::dragMove(MONITOR, (POINT - MONITOR->m_position) * MONITOR->m_scale);

            ScrollOverview::Dock::damageIfChanged(MONITOR);
        }
    });

    // X24 dock-side. The overview installs its own button hook; this one is the
    // plain desktop, where nothing else claims a click on the pill. Both edges
    // are swallowed over the pill: the dock is not a window, so a press that
    // reached the window underneath would focus it, and a release that leaked
    // after a swallowed press would leave the pointer stuck.
    static auto DOCKCLICK = Event::bus()->m_events.input.mouse.button.listen([](IPointer::SButtonEvent event, Event::SCallbackInfo& info) {
        if (event.button != BTN_LEFT)
            return;

        const auto POINT = g_pInputManager->getMouseCoordsInternal();
        for (const auto& MONITOR : State::monitorState()->monitors()) {
            if (!MONITOR || scrollOverviewForMonitor(MONITOR) || !MONITOR->logicalBox().containsPoint(POINT))
                continue;

            const auto LOCAL = (POINT - MONITOR->m_position) * MONITOR->m_scale;
            if (!ScrollOverview::Dock::pillContains(MONITOR, LOCAL)) {
                // X32. A drag released OFF the pill is a cancel, and the press
                // that started it was the dock's -- so this release is not a
                // click on the desktop either.
                if (event.state != WL_POINTER_BUTTON_STATE_PRESSED && ScrollOverview::Dock::dragPending()) {
                    ScrollOverview::Dock::dragCancel();
                    info.cancelled = true;
                }
                return;
            }

            info.cancelled = true;

            // X32. Press remembers, motion commits to a drag, release decides
            // which of the two gestures happened. See the same three lines in
            // scrollOverview.cpp's own button hook -- the overview's dock and
            // the desktop's are one dock and must not behave differently.
            if (event.state == WL_POINTER_BUTTON_STATE_PRESSED) {
                ScrollOverview::Dock::dragBegin(MONITOR, LOCAL);
                return;
            }

            if (ScrollOverview::Dock::dragEnd(MONITOR, LOCAL))
                return;

            const auto KEEB  = g_pSeatManager ? g_pSeatManager->m_keyboard.lock() : nullptr;
            const bool SHIFT = KEEB && (KEEB->getModifiers() & HL_MODIFIER_SHIFT);
            ScrollOverview::Dock::click(MONITOR, LOCAL, SHIFT);
            return;
        }
    });

    static auto DOCK = Event::bus()->m_events.render.stage.listen([](eRenderStage stage) {
        if (stage != RENDER_POST_WINDOWS)
            return;

        const auto MONITOR = g_pHyprRenderer->m_renderData.pMonitor.lock();
        if (scrollOverviewForMonitor(MONITOR))
            return;

        ScrollOverview::Dock::render(MONITOR);
    });

    ScrollOverview::Config::registerDispatcher("overview", ::onOverviewDispatcher);
    ScrollOverview::Config::registerDispatcher("navigate", ::onNavigateDispatcher);
    ScrollOverview::Config::registerDispatcher("window", ::onWindowDispatcher);
    ScrollOverview::Config::registerDispatcher("minimize", ::onMinimizeDispatcher);
    ScrollOverview::Config::registerGesture(::onRegisterOverviewGesture, ::overviewGestureKeyword);
    ScrollOverview::Config::registerConfig();
    registerTapSuper();

    return {"scrolloverview", "A plugin for an overview", "Vaxry, yayuuu", SCROLLOVERVIEW_VERSION};
}

APICALL EXPORT void PLUGIN_EXIT() {
    g_pHyprRenderer->m_renderPass.removeAllOfType("CScrollOverviewPassElement");

    g_pTapSuperKeyHook.reset();
    g_pTapSuperButtonHook.reset();

    g_unloading = true;
    // The D-Bus worker outlives the overview otherwise, and hyprpm reloads the
    // plugin in-process.
    SearchProviders::shutdown();
    ScrollOverview::LauncherEntry::stop();
    clearScrollOverviews();
    disableScrollOverviewHooks();

    if (g_pTrackpadGestures)
        g_pTrackpadGestures->clearGestures();

    HyprlandAPI::reloadConfig(); // re-adds built-in gestures cleared above
}
