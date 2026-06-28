#include "Config.hpp"

#include <algorithm>
#include <hyprland/src/config/values/types/BoolValue.hpp>
#include <hyprland/src/config/values/types/ColorValue.hpp>
#include <hyprland/src/config/values/types/FloatValue.hpp>
#include <hyprland/src/config/values/types/IntValue.hpp>
#include <hyprland/src/config/values/types/StringValue.hpp>
#include <hyprland/src/managers/KeybindManager.hpp>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

namespace {

ScrollOverview::Config::TOverviewDispatcher g_overviewDispatcher = nullptr;
ScrollOverview::Config::TGestureRegistrar   g_gestureRegistrar   = nullptr;

bool isOverviewArgValid(const std::string_view arg) {
    return arg == "toggle" || arg == "select" || arg == "on" || arg == "enable" || arg == "off" || arg == "disable";
}

int dispatchOverviewLua(lua_State* L, const char* arg) {
    if (!g_overviewDispatcher)
        return luaL_error(L, "overview: dispatcher is not registered");

    const auto result = g_overviewDispatcher(arg);
    if (!result.success)
        return luaL_error(L, "overview: %s", result.error.c_str());

    return 0;
}

int overviewDispatchToggleLua(lua_State* L) {
    return dispatchOverviewLua(L, "toggle");
}

int overviewDispatchSelectLua(lua_State* L) {
    return dispatchOverviewLua(L, "select");
}

int overviewDispatchOnLua(lua_State* L) {
    return dispatchOverviewLua(L, "on");
}

int overviewDispatchEnableLua(lua_State* L) {
    return dispatchOverviewLua(L, "enable");
}

int overviewDispatchOffLua(lua_State* L) {
    return dispatchOverviewLua(L, "off");
}

int overviewDispatchDisableLua(lua_State* L) {
    return dispatchOverviewLua(L, "disable");
}

int overviewLua(lua_State* L) {
    const char* arg = "toggle";

    if (lua_gettop(L) >= 1) {
        if (lua_isnoneornil(L, 1))
            return luaL_error(L, "overview: expected a string argument; did you forget quotes around it?");

        if (!lua_isstring(L, 1))
            return luaL_error(L, "overview: expected an optional string argument");

        arg = lua_tostring(L, 1);
    }

    if (!isOverviewArgValid(arg))
        return luaL_error(L, "overview: invalid argument '%s'", arg);

    if (g_pKeybindManager && g_pKeybindManager->m_currentKeybind && g_pKeybindManager->m_currentKeybind->handler == "__lua") {
        if (!g_overviewDispatcher)
            return luaL_error(L, "overview: dispatcher is not registered");

        const auto result = g_overviewDispatcher(arg);
        if (!result.success)
            return luaL_error(L, "overview: %s", result.error.c_str());

        return 0;
    }

    if (std::string_view{arg} == "toggle")
        lua_pushcfunction(L, overviewDispatchToggleLua);
    else if (std::string_view{arg} == "select")
        lua_pushcfunction(L, overviewDispatchSelectLua);
    else if (std::string_view{arg} == "on")
        lua_pushcfunction(L, overviewDispatchOnLua);
    else if (std::string_view{arg} == "enable")
        lua_pushcfunction(L, overviewDispatchEnableLua);
    else if (std::string_view{arg} == "off")
        lua_pushcfunction(L, overviewDispatchOffLua);
    else if (std::string_view{arg} == "disable")
        lua_pushcfunction(L, overviewDispatchDisableLua);
    else
        return luaL_error(L, "overview: invalid argument '%s'", arg);

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

void registerLua(TOverviewDispatcher dispatcher, TGestureRegistrar gestureRegistrar) {
    if (::Config::mgr()->type() != ::Config::CONFIG_LUA)
        return;

    g_overviewDispatcher = dispatcher;
    g_gestureRegistrar   = gestureRegistrar;
    HyprlandAPI::addLuaFunction(SCROLLOVERVIEW_HANDLE, "scrolloverview", "overview", ::overviewLua);
    HyprlandAPI::addLuaFunction(SCROLLOVERVIEW_HANDLE, "scrolloverview", "configure", ::configureLua);
    HyprlandAPI::addLuaFunction(SCROLLOVERVIEW_HANDLE, "scrolloverview", "gesture", ::gestureLua);
}

void registerLegacy() {
    using namespace ::Config::Values;

    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:gesture_distance", "gesture distance in pixels", 200, SIntValueOptions{.min = 1}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CFloatValue>("plugin:scrolloverview:scale", "overview scale", 0.5F, SFloatValueOptions{.min = 0.1F, .max = 0.9F}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:workspace_gap", "gap between overview workspaces", 0, SIntValueOptions{.min = 0}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CStringValue>("plugin:scrolloverview:layout", "overview layout", Hyprlang::STRING{"vertical"}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:input:scroll_event_delay", "minimum delay (ms) between discrete scroll steps (wheel workspace nav and trackpad focus stepping)", 200, SIntValueOptions{.min = 0}));
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
                                  makeShared<CIntValue>("plugin:scrolloverview:wallpaper", "wallpaper mode", 0, SIntValueOptions{.min = 0, .max = 2}));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE, makeShared<CBoolValue>("plugin:scrolloverview:blur", "blur the overview wallpaper", false));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CBoolValue>("plugin:scrolloverview:shadow:enabled", "draw a shadow around each workspace card", false));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:shadow:range", "workspace card shadow range", -1));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CIntValue>("plugin:scrolloverview:shadow:render_power", "workspace card shadow render power", -1));
    HyprlandAPI::addConfigValueV2(SCROLLOVERVIEW_HANDLE,
                                  makeShared<CColorValue>("plugin:scrolloverview:shadow:color", "workspace card shadow color", -1));
}

int getGestureDistance() {
    return std::max<int>(1, getValue<int>("plugin:scrolloverview:gesture_distance"));
}

float getScale() {
    return std::clamp(getValue<float>("plugin:scrolloverview:scale"), 0.1F, 0.9F);
}

int getWorkspaceGap() {
    return std::max<int>(0, getValue<int>("plugin:scrolloverview:workspace_gap"));
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
        default: return defaultVerticalScrollAction(layout);
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

::Config::CCssGapData getCssGapData(const std::string& name) {
    const auto VALUE = HyprlandAPI::getConfigValue(SCROLLOVERVIEW_HANDLE, name);
    if (!VALUE)
        return {};

    const auto CUSTOM = rc<Hyprlang::CUSTOMTYPE* const*>(VALUE->getDataStaticPtr());
    if (!CUSTOM || !*CUSTOM)
        return {};

    const auto* const GAPS = sc<::Config::CCssGapData*>((*CUSTOM)->getData());
    return GAPS ? *GAPS : ::Config::CCssGapData{};
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

int64_t getShadowColor() {
    return getValue<int64_t>("plugin:scrolloverview:shadow:color");
}

}
