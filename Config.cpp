#include "Config.hpp"

#include <chrono>

#include <algorithm>
#include <config/shared/complex/ComplexDataType.hpp>
#include <config/shared/complex/ComplexDataTypes.hpp>
#include <hyprland/src/config/values/types/BoolValue.hpp>
#include <hyprland/src/config/values/types/ColorValue.hpp>
#include <hyprland/src/config/values/types/FloatValue.hpp>
#include <hyprland/src/config/values/types/IntValue.hpp>
#include <hyprland/src/config/values/types/StringValue.hpp>
#include <hyprland/src/config/values/types/GradientValue.hpp>
#include <hyprland/src/managers/KeybindManager.hpp>

#include <regex>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

namespace {

ScrollOverview::Config::TGestureRegistrar g_gestureRegistrar   = nullptr;

int dispatcherFactoryLua(lua_State* L, std::string_view name);

using TArgValidator = bool (*)(std::string_view);

struct SDispatcher {
    std::string_view                    name;
    std::regex                          argPattern;
    std::string_view                    defaultArg;
    std::string_view                    typeArgError;
    std::string_view                    invalidArgError;
    TArgValidator                       argValidator = nullptr;
    ScrollOverview::Config::TDispatcher dispatcher   = nullptr;
    lua_CFunction                       luaFunction  = nullptr;

    bool isArgValid(const std::string_view arg) const {
        if (argValidator)
            return argValidator(arg);

        return std::regex_match(arg.begin(), arg.end(), argPattern);
    }
};

SDispatcher* findDispatcher(const std::string_view name) {
    static SDispatcher registrations[] = {
        {
            .name            = "overview",
            .argPattern      = std::regex{R"(^(select|(toggle|on|open|enable|off|close|disable)([ \t]+(all|[^ \t"\\]+))?)$)"},
            .defaultArg      = "toggle",
            .typeArgError    = "expected an optional string argument; did you forget quotes around it?",
            .invalidArgError = "expected select or toggle/open/close [monitor|all] (aliases: on, enable, off, disable)",
            .luaFunction     = [](lua_State* L) { return dispatcherFactoryLua(L, "overview"); },
        },
        {
            .name            = "navigate",
            .argPattern      = std::regex{"^(left|right|up|down)$"},
            .typeArgError    = "expected a string argument",
            .invalidArgError = "expected one of: left, right, up, down",
            .luaFunction     = [](lua_State* L) { return dispatcherFactoryLua(L, "navigate"); },
        },
        {
            .name            = "minimize",
            .argPattern      = std::regex{"^(window|restore)$"},
            .defaultArg      = "window",
            .typeArgError    = "expected an optional string argument; did you forget quotes around it?",
            .invalidArgError = "expected one of: window, restore",
            .luaFunction     = [](lua_State* L) { return dispatcherFactoryLua(L, "minimize"); },
        },
        {
            // X34. `1`..`10` are the reference's SLOT numbers, not the digits on
            // the keys -- `<Super>0` is the tenth app and so binds `10`. One
            // dispatcher for all thirty accelerators, because the reference has
            // one callback for all thirty and the modifier is an argument to it.
            .name            = "hotkey",
            .argPattern      = std::regex{"^(overlay|((shift|ctrl) )?([1-9]|10))$"},
            .typeArgError    = "expected a string argument",
            .invalidArgError = "expected overlay, or 1-10 optionally prefixed with 'shift ' or 'ctrl '",
            .luaFunction     = [](lua_State* L) { return dispatcherFactoryLua(L, "hotkey"); },
        },
        {
            .name            = "window",
            .argPattern      = std::regex{"^(select|close|click)$"},
            .typeArgError    = "expected a string argument",
            .invalidArgError = "expected one of: select, close, click",
            .luaFunction     = [](lua_State* L) { return dispatcherFactoryLua(L, "window"); },
        },
    };

    const auto MATCH = std::ranges::find_if(registrations, [name](const auto& registration) { return registration.name == name; });
    return MATCH == std::end(registrations) ? nullptr : &*MATCH;
}

int runDispatcherNow(lua_State* L, const SDispatcher& dispatcher, const char* arg) {
    if (!dispatcher.dispatcher)
        return luaL_error(L, "%s: dispatcher is not registered", dispatcher.name.data());

    const auto result = dispatcher.dispatcher(arg);
    if (!result.success)
        return luaL_error(L, "%s: %s", dispatcher.name.data(), result.error.c_str());

    return 0;
}

void pushDispatcherBindAction(lua_State* L, const char* name, const char* arg) {
    const std::string CODE = "return function() return hl.plugin.scrolloverview._dispatch(\"" + std::string{name} + "\", \"" + std::string{arg} + "\") end";

    if (luaL_loadstring(L, CODE.c_str()) != LUA_OK)
        lua_error(L);

    if (lua_pcall(L, 0, 1, 0) != LUA_OK)
        lua_error(L);
}

int runDispatcherActionLua(lua_State* L) {
    if (lua_gettop(L) < 2 || lua_isnoneornil(L, 1) || lua_isnoneornil(L, 2))
        return luaL_error(L, "_dispatch: expected dispatcher name and argument");

    if (!lua_isstring(L, 1) || !lua_isstring(L, 2))
        return luaL_error(L, "_dispatch: expected string arguments");

    const char* name = lua_tostring(L, 1);
    const char* arg  = lua_tostring(L, 2);
    const auto  DISPATCHER = findDispatcher(name);

    if (!DISPATCHER)
        return luaL_error(L, "_dispatch: unknown dispatcher '%s'", name);
    if (!DISPATCHER->isArgValid(arg))
        return luaL_error(L, "%s: invalid argument '%s', %s", name, arg, DISPATCHER->invalidArgError.data());

    return runDispatcherNow(L, *DISPATCHER, arg);
}

int dispatcherFactoryLua(lua_State* L, std::string_view name) {
    const auto DISPATCHER = findDispatcher(name);
    if (!DISPATCHER)
        return luaL_error(L, "%s: dispatcher metadata is not registered", name.data());

    const char* arg = DISPATCHER->defaultArg.empty() ? nullptr : DISPATCHER->defaultArg.data();

    if (!arg && (lua_gettop(L) < 1 || lua_isnoneornil(L, 1)))
        return luaL_error(L, "%s: %s", DISPATCHER->name.data(), DISPATCHER->typeArgError.data());

    if (lua_gettop(L) >= 1) {
        if (lua_isnoneornil(L, 1))
            return luaL_error(L, "%s: %s", DISPATCHER->name.data(), DISPATCHER->typeArgError.data());

        if (!lua_isstring(L, 1))
            return luaL_error(L, "%s: %s", DISPATCHER->name.data(), DISPATCHER->typeArgError.data());

        arg = lua_tostring(L, 1);
    }

    if (!DISPATCHER->isArgValid(arg))
        return luaL_error(L, "%s: invalid argument '%s', %s", DISPATCHER->name.data(), arg, DISPATCHER->invalidArgError.data());

    if (g_pKeybindManager && g_pKeybindManager->m_currentKeybind && g_pKeybindManager->m_currentKeybind->handler == "__lua") {
        return runDispatcherNow(L, *DISPATCHER, arg);
    }

    pushDispatcherBindAction(L, DISPATCHER->name.data(), arg);

    return 1;
}

int configureLua(lua_State* L) {
    if (!lua_istable(L, 1))
        return luaL_error(L, "configure: expected a table");

    const int CONFIG = lua_absindex(L, 1);

    lua_getglobal(L, "hl");
    if (!lua_istable(L, -1))
        return luaL_error(L, "configure: global hl table is not available");

    lua_getfield(L, -1, "config");
    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        return luaL_error(L, "configure: hl.config is not available");
    }

    lua_newtable(L);
    lua_newtable(L);
    lua_pushvalue(L, CONFIG);
    lua_setfield(L, -2, "scrolloverview");
    lua_setfield(L, -2, "plugin");

    if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
        const char* err = lua_tostring(L, -1);
        lua_pop(L, 2);
        return luaL_error(L, "configure: %s", err ? err : "hl.config failed");
    }

    lua_pop(L, 1);

    return 0;
}

int gestureLua(lua_State* L) {
    if (!g_gestureRegistrar)
        return luaL_error(L, "gesture: registrar is not registered");

    if (!lua_istable(L, 1))
        return luaL_error(L, "gesture: expected a table, e.g. { fingers = 3, direction = \"up\" }");

    lua_getfield(L, 1, "fingers");
    if (!lua_isinteger(L, -1))
        return luaL_error(L, "gesture: 'fingers' (integer) is required");
    const size_t FINGERS = sc<size_t>(lua_tointeger(L, -1));
    lua_pop(L, 1);

    lua_getfield(L, 1, "direction");
    if (!lua_isstring(L, -1))
        return luaL_error(L, "gesture: 'direction' (string) is required");
    const std::string DIRECTION = lua_tostring(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, 1, "action");
    const std::string ACTION = lua_isstring(L, -1) ? lua_tostring(L, -1) : "overview";
    lua_pop(L, 1);

    // accept either "mods" or "mod"
    lua_getfield(L, 1, "mods");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_getfield(L, 1, "mod");
    }
    const std::string MODS = lua_isstring(L, -1) ? lua_tostring(L, -1) : "";
    lua_pop(L, 1);

    lua_getfield(L, 1, "scale");
    const float SCALE = lua_isnumber(L, -1) ? sc<float>(lua_tonumber(L, -1)) : 1.F;
    lua_pop(L, 1);

    lua_getfield(L, 1, "disable_inhibit");
    const bool DISABLE_INHIBIT = lua_toboolean(L, -1);
    lua_pop(L, 1);

    const auto result = g_gestureRegistrar(FINGERS, DIRECTION, ACTION, MODS, SCALE, DISABLE_INHIBIT);
    if (!result.success)
        return luaL_error(L, "gesture: %s", result.error.c_str());

    return 0;
}

}

namespace ScrollOverview::Config {

void registerDispatcher(const std::string& name, TDispatcher dispatcher) {
    HyprlandAPI::addDispatcherV2(SCROLLOVERVIEW_HANDLE, "scrolloverview:" + name, dispatcher);

    if (::Config::mgr()->type() != ::Config::CONFIG_LUA)
        return;

    const auto DISPATCHER = findDispatcher(name);
    if (!DISPATCHER)
        return;

    DISPATCHER->dispatcher = dispatcher;
    HyprlandAPI::addLuaFunction(SCROLLOVERVIEW_HANDLE, "scrolloverview", std::string{DISPATCHER->name}, DISPATCHER->luaFunction);
}

void registerGesture(TGestureRegistrar gestureRegistrar, TGestureKeyword gestureKeyword) {
    HyprlandAPI::addConfigKeyword(SCROLLOVERVIEW_HANDLE, "scrolloverview-gesture", gestureKeyword, {});

    if (::Config::mgr()->type() != ::Config::CONFIG_LUA)
        return;

    g_gestureRegistrar = gestureRegistrar;
    HyprlandAPI::addLuaFunction(SCROLLOVERVIEW_HANDLE, "scrolloverview", "gesture", ::gestureLua);
}

static void registerLuaFunctions() {
    if (::Config::mgr()->type() != ::Config::CONFIG_LUA)
        return;

    HyprlandAPI::addLuaFunction(SCROLLOVERVIEW_HANDLE, "scrolloverview", "_dispatch", ::runDispatcherActionLua);
    HyprlandAPI::addLuaFunction(SCROLLOVERVIEW_HANDLE, "scrolloverview", "configure", ::configureLua);
}

static void registerConfigValues() {
    using namespace ::Config::Values;

    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:gesture_distance", "gesture distance in pixels", 200, SIntValueOptions{.min = 1}));
    // Default alpha 0 = unset; highlightColor() then falls back to the theme's
    // border accent, which is what every build before this one used.
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CGradientValue>("plugin:scrolloverview:col_highlight",
                                                             "colour of the selection/hover highlights; unset falls back to general:col.active_border",
                                                             CHyprColor{0.F, 0.F, 0.F, 0.F}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CFloatValue>("plugin:scrolloverview:scale", "overview scale", 0.82F, SFloatValueOptions{.min = 0.1F, .max = 0.9F}));
    // GLOBAL ANIMATION SPEED. 1 = shipped timings, higher = slower, and it
    // reaches EVERYTHING through animElapsedMs: the overview's open/close, the
    // dock's hover panel, the minimize flight, tooltips, the bounce, the launch
    // zoom. For watching a frame at a time, and for the stress rig.
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CFloatValue>("plugin:scrolloverview:anim_scale", "global animation slowdown; 1 = normal, 10 = ten times slower", 1.F,
                                                          SFloatValueOptions{.min = 0.05F, .max = 100.F}));

    // The overview used to borrow `windowsMove` for its own open and close,
    // which meant one curve for both directions and no way to shape either
    // without also changing how every window on the desk moves. These are in
    // Hyprland's animation units -- tenths of a second, so 3.0 is 300ms.
    //
    // The defaults are the house motion rule: an entrance decelerates, an exit
    // accelerates and is ~25% shorter, and neither overshoots.
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CFloatValue>("plugin:scrolloverview:open_speed", "overview open duration, tenths of a second", 2.6F,
                                                          SFloatValueOptions{.min = 0.1F, .max = 20.F}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CFloatValue>("plugin:scrolloverview:close_speed", "overview close duration, tenths of a second", 1.9F,
                                                          SFloatValueOptions{.min = 0.1F, .max = 20.F}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:workspace_gap", "gap between overview workspaces", 40, SIntValueOptions{.min = 0}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CStringValue>("plugin:scrolloverview:layout", "overview layout", Hyprlang::STRING{"vertical"}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CStringValue>("plugin:scrolloverview:terminal", "terminal used to launch Terminal=true desktop entries; empty falls back to $TERMINAL",
                                                           Hyprlang::STRING{""}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:input:scroll_event_delay", "minimum delay (ms) between discrete scroll steps (wheel workspace nav and trackpad focus stepping)", 200, SIntValueOptions{.min = 0}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CFloatValue>("plugin:scrolloverview:input:touchpad_scroll_factor", "overview touchpad scroll factor", 1.F,
                                                          SFloatValueOptions{.min = 0.F}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:input:left_handed", "overview left handed mouse buttons, 2 follows input:left_handed", 2,
                                                        SIntValueOptions{.min = 0, .max = 2}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:input:scrolling_mode", "overview mouse wheel behavior", 0,
                                                        SIntValueOptions{.min = 0, .max = 3}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:input:drag_mode", "overview mouse drag behavior", 0,
                                                        SIntValueOptions{.min = 0, .max = 1}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:input:drag_threshold", "overview drag threshold", 10,
                                                        SIntValueOptions{.min = 0}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CFloatValue>("plugin:scrolloverview:drag_mini_scale",
                                                          "size of the drag proxy while it hovers another workspace, as a fraction of its tile size", 0.45F,
                                                          SFloatValueOptions{.min = 0.05F, .max = 1.F}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:drag_mini_ms", "ms for the drag proxy to shrink to, or grow back from, mini scale", 150,
                                                        SIntValueOptions{.min = 0}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:drag_recentre_ms",
                                                        "ms for the drag proxy's grab point to slide to its centre while over a drop target", 160,
                                                        SIntValueOptions{.min = 0}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:wallpaper", "wallpaper mode", 0, SIntValueOptions{.min = 0, .max = 2}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE, makeShared<CBoolValue>("plugin:scrolloverview:blur", "blur the overview wallpaper", false));

    // OVERVIEW_CPP_SPEC §13.9. Defaults are the user's dumped Dash to Dock
    // config, not upstream defaults. Real keys from day one so hyprsettings
    // (X36-X40) has something to bind to.
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE, makeShared<CBoolValue>("plugin:scrolloverview:dock:enabled", "hyprgnomedock: draw the dock", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:dock:icon_size", "hyprgnomedock: max icon size (dash-max-icon-size)", 54,
                                                        SIntValueOptions{.min = 8, .max = 512}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CFloatValue>("plugin:scrolloverview:dock:height_fraction",
                                                          "hyprgnomedock: max fraction of the monitor's long axis the dock may span", 0.90F,
                                                          SFloatValueOptions{.min = 0.05F, .max = 1.F}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:dock:corner_radius", "hyprgnomedock: pill corner radius", 24,
                                                        SIntValueOptions{.min = 0}));
    // X24. 220ms because the standing Apple-motion rule puts entrances at ~300ms
    // and makes exits 20-30% faster; a minimize is an exit.
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:dock:minimize_ms",
                                                        "hyprgnomedock: minimize/restore flight duration, 0 to teleport (Y5: GNOME's MINIMIZE_WINDOW_ANIMATION_TIME)", 400,
                                                        SIntValueOptions{.min = 0, .max = 2000}));
    // X30. The reference's autohide numbers, verbatim. `intellihide` is false
    // there and inert while off, so it is not a key here.
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:autohide", "hyprgnomedock: hide the dock until the bottom edge is pressed (D2D autohide)", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CFloatValue>("plugin:scrolloverview:dock:pressure_threshold",
                                                          "hyprgnomedock: px of motion pushed into the bottom edge before the dock reveals (D2D pressure-threshold)", 100.F,
                                                          SFloatValueOptions{.min = 0.F, .max = 2000.F}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:dock:show_delay_ms", "hyprgnomedock: delay from the barrier trigger to the reveal (D2D show-delay)", 250,
                                                        SIntValueOptions{.min = 0, .max = 5000}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:dock:hide_delay_ms", "hyprgnomedock: delay from the pointer leaving to the hide (D2D hide-delay)", 200,
                                                        SIntValueOptions{.min = 0, .max = 5000}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:dock:autohide_ms", "hyprgnomedock: slide duration (D2D animation-time)", 200,
                                                        SIntValueOptions{.min = 0, .max = 2000}));
    // X31. The dot's two numbers are GNOME SHELL's, not D2D's: the reference runs
    // `running-indicator-style` DEFAULT, which draws no dot of its own and leaves
    // the shell's own showing -- `.app-grid-running-dot`, 5px, #fafafb.
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:running_indicator", "hyprgnomedock: dot under a running app's icon (D2D show-running)", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CColorValue>("plugin:scrolloverview:dock:indicator_color", "hyprgnomedock: running-dot colour (shell .app-grid-running-dot)",
                                                          (Hyprlang::INT)0xFFFAFAFB));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:dock:indicator_size", "hyprgnomedock: running-dot diameter in px", 5,
                                                        SIntValueOptions{.min = 1, .max = 64}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:notification_counter",
                                                         "hyprgnomedock: red count badge on the icon (D2D show-icons-notifications-counter)", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:emblems", "hyprgnomedock: draw Unity LauncherEntry emblems at all (D2D show-icons-emblems)", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:dance_urgent", "hyprgnomedock: wiggle an urgent app's icon (D2D dance-urgent-applications)", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:urgent_notify",
                                                         "hyprgnomedock: reveal the dock when an app goes urgent (D2D show-dock-urgent-notify)", true));
    // X32. `show-favorites`, `show-show-apps-button`, `show-apps-at-top` and
    // `show-apps-always-in-the-edge`, at the reference's values. The last two are
    // a pair: false/true is what puts the button at the right-hand end of a
    // bottom dock rather than in among the apps.
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:flight_log", "flight lifecycle log to /tmp/ovdbg.log, for scripts/z_rig.sh + zflight_gate.py", false));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:show_favorites", "hyprgnomedock: pinned apps in the dock whether running or not (D2D show-favorites)", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:show_apps_button", "hyprgnomedock: the Show Applications button (D2D show-show-apps-button)", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:show_apps_at_top", "hyprgnomedock: Show Applications at the START of the dock (D2D show-apps-at-top)", false));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:show_apps_always_in_the_edge",
                                                         "hyprgnomedock: keep Show Applications hard against the dock's edge (D2D show-apps-always-in-the-edge)", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CStringValue>("plugin:scrolloverview:dock:show_apps_icon", "hyprgnomedock: Show Applications artwork", Hyprlang::STRING{"view-app-grid-symbolic"}));

    // X33. Scroll and middle-click.
    //
    // `scroll-switch-workspace` is NOT a key here, and that is a finding rather
    // than an omission: it is VESTIGIAL in the reference. It survives in the
    // gschema but nothing reads it -- grepped docking.js, appIcons.js, dash.js
    // and prefs.js at master. The switch is `scroll-action='switch-workspace'`,
    // the SAME setting that turns icon cycling off
    // (`_optionalScrollWorkspaceSwitch` binds its handler only when scrollAction
    // is SWITCH_WORKSPACE, `_optionalScrollCycleWindows` only when it is
    // CYCLE_WINDOWS), so the two behaviours are mutually exclusive and one enum
    // is the whole setting.
    //
    // `scroll-to-focused-application` is not a key either: it scrolls a dash
    // that has OVERFLOWED so the focused icon stays in view. This pill never
    // overflows -- the icon size shrinks against height_fraction until it fits --
    // so the requirement holds by construction and a key would be a no-op.
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CStringValue>("plugin:scrolloverview:dock:scroll_action",
                                                           "hyprgnomedock: wheel over the dock: cycle-windows | switch-workspace | do-nothing (D2D scroll-action)",
                                                           Hyprlang::STRING{"cycle-windows"}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CStringValue>("plugin:scrolloverview:dock:middle_click_action",
                                                           "hyprgnomedock: middle click on an icon: launch | minimize | cycle-windows | quit | skip (D2D middle-click-action)",
                                                           Hyprlang::STRING{"launch"}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CStringValue>("plugin:scrolloverview:dock:shift_middle_click_action",
                                                           "hyprgnomedock: shift+middle click on an icon (D2D shift-middle-click-action)", Hyprlang::STRING{"launch"}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:isolate_workspaces",
                                                         "hyprgnomedock: the dock lists only windows on the current workspace (D2D isolate-workspaces)", false));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:workspace_agnostic_urgent",
                                                         "hyprgnomedock: an urgent window stays listed even when isolate_workspaces hides its workspace "
                                                         "(D2D workspace-agnostic-urgent-windows)",
                                                         true));

    // X34. The accelerators are NOT keys -- Hyprland's own `bind` lines are the
    // store GNOME uses gsettings for. These four are the behaviour around them.
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:hot_keys", "hyprgnomedock: Super+number activates dock apps (D2D hot-keys)", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:hotkeys_overlay",
                                                         "hyprgnomedock: a hotkey press draws the slot numbers on the icons (D2D hotkeys-overlay)", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:hotkeys_show_dock",
                                                         "hyprgnomedock: a hotkey press reveals a hidden dock while the overlay is up (D2D hotkeys-show-dock)", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CFloatValue>("plugin:scrolloverview:dock:shortcut_timeout",
                                                          "hyprgnomedock: seconds the number overlay stays up (D2D shortcut-timeout)", 2.F,
                                                          SFloatValueOptions{.min = 0.F, .max = 10.F}));

    // X35. The dock's non-app items. `show_mounts` is the MASTER switch in the
    // reference -- `_ensureLocations` never constructs `Removables` while it is
    // off, so the two keys under it are read by nothing -- and it is false in the
    // target config. The trash is therefore the only location the rice draws.
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:show_trash", "hyprgnomedock: a Trash item at the end of the dock (D2D show-trash)", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:show_mounts", "hyprgnomedock: mounted volumes as dock items (D2D show-mounts)", false));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:show_mounts_network",
                                                         "hyprgnomedock: include network shares among the mounts (D2D show-mounts-network)", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:show_mounts_only_mounted",
                                                         "hyprgnomedock: only volumes that are mounted, not every one present (D2D show-mounts-only-mounted)", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:dock:isolate_locations",
                                                         "hyprgnomedock: a location's running state is its own, not the file manager's (D2D isolate-locations)", true));

    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CColorValue>("plugin:scrolloverview:dock:background_color", "hyprgnomedock: pill hue (alpha comes from background_opacity)",
                                                          (Hyprlang::INT)0xFFC0BFBC));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CFloatValue>("plugin:scrolloverview:dock:background_opacity", "hyprgnomedock: pill alpha (D2D background-opacity)", 0.19F,
                                                          SFloatValueOptions{.min = 0.F, .max = 1.F}));
    // X29. The dock's frost is blur-my-shell's `[dash-to-dock]`, not the desktop's
    // window blur: sigma 30, brightness 0.60, live (static-blur false), and no
    // grain. Hyprland's dual-kawase has no sigma at all, so size/passes are not
    // converted, they are MEASURED: 7/3 fits a gaussian of sigma 29.5 against the
    // real backdrop (share/x29/x29_gate.py). 15/2 fits 30.0 just as closely and
    // was passed over because more passes is the better gaussian approximation,
    // which is what the reference actually applies.
    //
    // (user, 2026-08-06): those measurements are KEPT as documentation but are no
    // longer the DEFAULT. "All of those blur configs for those different elements
    // need to be just inherited from hyprland settings" -- the dock was the only
    // surface in the plugin carrying its own blur, which is why it read as a
    // different material from the strip and the cards beside it. Every key below
    // now defaults to -1 = follow decoration:blur:*, and setting any of them back
    // to the numbers above restores the blur-my-shell match for anyone who wants
    // GNOME's dock rather than their own theme's.
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:dock:blur_size", "hyprgnomedock: blur size (-1 = follow decoration:blur:size)", -1,
                                                        SIntValueOptions{.min = -1, .max = 64}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:dock:blur_passes", "hyprgnomedock: blur passes (-1 = follow decoration:blur:passes)", -1,
                                                        SIntValueOptions{.min = -1, .max = 10}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CFloatValue>("plugin:scrolloverview:dock:blur_brightness",
                                                          "hyprgnomedock: blur brightness (blur-my-shell brightness; -1 = follow decoration:blur:brightness)", -1.F,
                                                          SFloatValueOptions{.min = -1.F, .max = 2.F}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CFloatValue>("plugin:scrolloverview:dock:blur_noise",
                                                          "hyprgnomedock: blur grain; the reference has none (-1 = follow decoration:blur:noise)", -1.F,
                                                          SFloatValueOptions{.min = -1.F, .max = 1.F}));
    // blur-my-shell applies a gaussian and a brightness and nothing else. Leaving
    // Hyprland's contrast at 0.89 and vibrancy at 0.5 in place put an affine term
    // and a saturation boost on top of that, which is a different look -- and it
    // made the measured brightness unrecoverable (it fitted 1.26 with a -51 offset).
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CFloatValue>("plugin:scrolloverview:dock:blur_contrast",
                                                          "hyprgnomedock: blur contrast; the reference applies none (-1 = follow decoration:blur:contrast)", -1.F,
                                                          SFloatValueOptions{.min = -1.F, .max = 2.F}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CFloatValue>("plugin:scrolloverview:dock:blur_vibrancy",
                                                          "hyprgnomedock: blur vibrancy; the reference applies none (-1 = follow decoration:blur:vibrancy)", -1.F,
                                                          SFloatValueOptions{.min = -1.F, .max = 1.F}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:live_layer_frost",
                                                         "evaluate dock/bar frost against the overview backdrop instead of the stale optimized blur FB", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CFloatValue>("plugin:scrolloverview:prefilter_below",
                                                          "mipmap-prefilter a tile's texture when it is minified below this fraction (0 = never)", 0.55F,
                                                          SFloatValueOptions{.min = 0.F, .max = 1.F}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:mission_control", "lay the focused workspace out as a mission-control grid", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:mission_control_gap", "gap between mission-control grid tiles", 40, SIntValueOptions{.min = 0}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:mission_control_reflow_ms", "ms for a grid tile to travel to a new slot", 300, SIntValueOptions{.min = 0}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:strip", "workspace thumbnail strip across the top of the overview", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:strip_height", "logical px the strip band reserves at the top of the workspace", 260,
                                                        SIntValueOptions{.min = 0}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:strip_gap", "gap between strip cells", 5, SIntValueOptions{.min = 0}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:tap_super", "tapping SUPER alone toggles the overview", true));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:tap_super_timeout_ms", "longest press-to-release still counted as a SUPER tap (0 = no limit)",
                                                        250, SIntValueOptions{.min = 0}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:shadow:enabled", "draw a shadow around each workspace card", false));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:shadow:range", "workspace card shadow range", -1));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:shadow:render_power", "workspace card shadow render power", -1));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CGradientValue>("plugin:scrolloverview:shadow:color", "workspace card shadow color", -1));
}

void registerConfig() {
    registerLuaFunctions();
    registerConfigValues();
    HyprlandAPI::reloadConfig();
}

int getGestureDistance() {
    return std::max<int>(1, getValue<int>("plugin:scrolloverview:gesture_distance"));
}

CHyprColor highlightColor() {
    if (const auto HIGHLIGHT = getValue<::Config::CGradientValueData>("plugin:scrolloverview:col_highlight");
        !HIGHLIGHT.m_colors.empty() && HIGHLIGHT.m_colors[0].a > 0.001F)
        return HIGHLIGHT.m_colors[0];

    const auto ACCENT = getValue<::Config::CGradientValueData>("general:col.active_border");
    return ACCENT.m_colors.empty() ? CHyprColor{1.F, 1.F, 1.F, 1.F} : ACCENT.m_colors[0];
}

CHyprColor highlightForeground() {
    const auto BG = highlightColor();

    // Rec. 709 relative luminance. Deciding this from the colour rather than
    // hardcoding either answer is what makes it survive a theme switch in
    // EITHER direction -- a light accent and a dark one both stay readable.
    if (const float LUMA = (0.2126F * BG.r) + (0.7152F * BG.g) + (0.0722F * BG.b); LUMA <= 0.55F)
        return CHyprColor{1.F, 1.F, 1.F, 1.F};

    // Not flat black: the accent's own dark end reads as the same material,
    // where black on a warm pink reads as a hole punched through it.
    return CHyprColor{BG.r * 0.18F, BG.g * 0.18F, BG.b * 0.18F, 1.F};
}

float getScale() {
    return std::clamp(getValue<float>("plugin:scrolloverview:scale"), 0.1F, 0.9F);
}

float getOpenSpeed() {
    return std::max(0.1F, getValue<float>("plugin:scrolloverview:open_speed"));
}

float getCloseSpeed() {
    return std::max(0.1F, getValue<float>("plugin:scrolloverview:close_speed"));
}

int getWorkspaceGap() {
    return std::max<int>(0, getValue<int>("plugin:scrolloverview:workspace_gap"));
}

std::string getTerminal() {
    return getValue<std::string>("plugin:scrolloverview:terminal");
}

ELayout getLayout() {
    const auto LAYOUT = getValue<std::string>("plugin:scrolloverview:layout");
    return LAYOUT == "horizontal" ? ELayout::HORIZONTAL : ELayout::VERTICAL;
}

bool getLeftHanded() {
    const auto LEFT_HANDED = getValue<int>("plugin:scrolloverview:input:left_handed");
    if (LEFT_HANDED <= 1)
        return LEFT_HANDED != 0;

    return getValue<bool>("input:left_handed");
}

int getDragMode() {
    return std::clamp(getValue<int>("plugin:scrolloverview:input:drag_mode"), 0, 1);
}

int getDragThreshold() {
    return std::max<int>(0, getValue<int>("plugin:scrolloverview:input:drag_threshold"));
}

float animScale() {
    return std::max(0.05F, getValue<float>("plugin:scrolloverview:anim_scale"));
}

// The ONE place the plugin's clock is read. Dividing here is what makes a single
// slider stretch every animation at once while every duration constant keeps its
// real value -- see the note in Config.hpp.
float animElapsedMs(const Time::steady_tp& since) {
    return sc<float>(std::chrono::duration<float, std::milli>(Time::steadyNow() - since).count()) / animScale();
}

float getTouchpadScrollFactor() {
    static constexpr float OVERVIEWTOUCHPADSCROLLFACTOR = 1.5F;

    return OVERVIEWTOUCHPADSCROLLFACTOR * std::max<float>(0.F, getValue<float>("input:touchpad:scroll_factor")) *
        std::max<float>(0.F, getValue<float>("plugin:scrolloverview:input:touchpad_scroll_factor"));
}

static EScrollAction defaultVerticalScrollAction(ELayout layout) {
    return layout == ELayout::HORIZONTAL ? EScrollAction::COLUMN : EScrollAction::WORKSPACE;
}

EScrollAction getVerticalScrollAction(ELayout layout) {
    const auto MODE = std::clamp(getValue<int>("plugin:scrolloverview:input:scrolling_mode"), 0, 3);

    switch (MODE) {
        case 1: return defaultVerticalScrollAction(layout) == EScrollAction::WORKSPACE ? EScrollAction::COLUMN : EScrollAction::WORKSPACE;
        case 2: return EScrollAction::WORKSPACE;
        case 3: return EScrollAction::COLUMN;
        case 0:
        // ponytail: mission control draws a grid, not scrolling columns, so COLUMN
        // has nothing to select there - the vertical wheel is only useful as a
        // desktop switch. Explicit scrolling_mode above still overrides this.
        default: return getMissionControl() ? EScrollAction::WORKSPACE : defaultVerticalScrollAction(layout);
    }
}

EScrollAction getHorizontalScrollAction(ELayout layout) {
    return getVerticalScrollAction(layout) == EScrollAction::WORKSPACE ? EScrollAction::COLUMN : EScrollAction::WORKSPACE;
}

int getScrollEventDelay() {
    return std::max<int>(0, getValue<int>("plugin:scrolloverview:input:scroll_event_delay"));
}

int getWallpaperMode() {
    return std::clamp<int>(getValue<int>("plugin:scrolloverview:wallpaper"), 0, 2);
}

bool getBlur() {
    return getValue<bool>("plugin:scrolloverview:blur");
}

bool getMissionControl() {
    return getValue<bool>("plugin:scrolloverview:mission_control");
}

int getMissionControlGap() {
    return std::max<int>(0, getValue<int>("plugin:scrolloverview:mission_control_gap"));
}

int getMissionControlReflowMs() {
    return std::max<int>(0, getValue<int>("plugin:scrolloverview:mission_control_reflow_ms"));
}

bool getStrip() {
    return getValue<bool>("plugin:scrolloverview:strip");
}

int getStripHeight() {
    return std::max<int>(0, getValue<int>("plugin:scrolloverview:strip_height"));
}

int getStripGap() {
    return std::max<int>(0, getValue<int>("plugin:scrolloverview:strip_gap"));
}

float getDragMiniScale() {
    return std::clamp(getValue<float>("plugin:scrolloverview:drag_mini_scale"), 0.05F, 1.F);
}

int getDragMiniMs() {
    return std::max<int>(0, getValue<int>("plugin:scrolloverview:drag_mini_ms"));
}

int getDragRecentreMs() {
    return std::max<int>(0, getValue<int>("plugin:scrolloverview:drag_recentre_ms"));
}

bool getTapSuper() {
    return getValue<bool>("plugin:scrolloverview:tap_super");
}

int getTapSuperTimeoutMs() {
    return std::max<int>(0, getValue<int>("plugin:scrolloverview:tap_super_timeout_ms"));
}

::Config::CCssGapData getCssGapData(const std::string& name) {
    auto& VALUE = valueRef<::Config::IComplexConfigValue>(name);
    if (!VALUE.good())
        return {};

    auto* const GAPS = dc<::Config::CCssGapData*>(VALUE.ptr());
    if (!GAPS)
        return {};

    return *GAPS;
}

int getShadowEnabled() {
    return getValue<bool>("plugin:scrolloverview:shadow:enabled") ? 1 : 0;
}

int getShadowRange() {
    return getValue<int>("plugin:scrolloverview:shadow:range");
}

int getShadowRenderPower() {
    return getValue<int>("plugin:scrolloverview:shadow:render_power");
}

std::optional<::Config::CGradientValueData> getShadowColor() {
    constexpr auto NAME = "plugin:scrolloverview:shadow:color";

    if (!::Config::mgr()->getConfigValue(NAME).setByUser)
        return std::nullopt;

    return getValue<::Config::CGradientValueData>(NAME);
}

}
