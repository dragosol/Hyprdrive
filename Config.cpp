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

}

namespace ScrollOverview::Config {

void registerLua(TOverviewDispatcher dispatcher) {
    if (::Config::mgr()->type() != ::Config::CONFIG_LUA)
        return;

    g_overviewDispatcher = dispatcher;
    HyprlandAPI::addLuaFunction(SCROLLOVERVIEW_HANDLE, "scrolloverview", "overview", ::overviewLua);
    HyprlandAPI::addLuaFunction(SCROLLOVERVIEW_HANDLE, "scrolloverview", "configure", ::configureLua);
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
    HyprlandAPI::addConfigValueV2(
        SCROLLOVERVIEW_HANDLE,
        makeShared<CIntValue>("plugin:scrolloverview:scroll_event_delay", "minimum delay (ms) between discrete scroll steps (wheel workspace nav and trackpad focus stepping)", 200,
                              SIntValueOptions{.min = 0}));
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

int getScrollEventDelay() {
    return std::max<int>(0, getValue<int>("plugin:scrolloverview:scroll_event_delay"));
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

    const auto CUSTOM = (Hyprlang::CUSTOMTYPE* const*)(VALUE->getDataStaticPtr());
    if (!CUSTOM || !*CUSTOM)
        return {};

    const auto* const GAPS = static_cast<::Config::CCssGapData*>((*CUSTOM)->getData());
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
