#include "Config.hpp"

#include <algorithm>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

namespace {

SScrollOverviewLuaConfig                      g_luaConfig;
ScrollOverview::Config::TOverviewDispatcher  g_overviewDispatcher = nullptr;

int getLegacyPluginIntValueOr(const std::string& name, int fallback) {
    if (::Config::mgr()->type() == ::Config::CONFIG_LUA)
        return fallback;

    const auto VALUE = HyprlandAPI::getConfigValue(SCROLLOVERVIEW_HANDLE, name);
    if (!VALUE)
        return fallback;

    const auto DATA = reinterpret_cast<Hyprlang::INT* const*>(VALUE->getDataStaticPtr());
    if (!DATA || !*DATA)
        return fallback;

    return sc<int>(**DATA);
}

int overviewLua(lua_State* L) {
    if (!g_overviewDispatcher)
        return luaL_error(L, "overview: dispatcher is not registered");

    const char* arg = "toggle";

    if (lua_gettop(L) >= 1 && !lua_isnoneornil(L, 1)) {
        if (!lua_isstring(L, 1))
            return luaL_error(L, "overview: expected an optional string argument");

        arg = lua_tostring(L, 1);
    }

    const auto result = g_overviewDispatcher(arg);
    if (!result.success)
        return luaL_error(L, "overview: %s", result.error.c_str());

    return 0;
}

int configureLua(lua_State* L) {
    if (!lua_istable(L, 1))
        return luaL_error(L, "configure: expected a table");

    const int TABLE = lua_absindex(L, 1);

    const auto readInt = [L, TABLE](const char* name, std::optional<int>& target) -> bool {
        lua_getfield(L, TABLE, name);
        if (lua_isnil(L, -1)) {
            lua_pop(L, 1);
            return true;
        }

        if (!lua_isinteger(L, -1)) {
            lua_pop(L, 1);
            luaL_error(L, "configure: %s must be an integer", name);
            return false;
        }

        target = sc<int>(lua_tointeger(L, -1));
        lua_pop(L, 1);
        return true;
    };

    const auto readFloat = [L, TABLE](const char* name, std::optional<float>& target) -> bool {
        lua_getfield(L, TABLE, name);
        if (lua_isnil(L, -1)) {
            lua_pop(L, 1);
            return true;
        }

        if (!lua_isnumber(L, -1)) {
            lua_pop(L, 1);
            luaL_error(L, "configure: %s must be a number", name);
            return false;
        }

        target = sc<float>(lua_tonumber(L, -1));
        lua_pop(L, 1);
        return true;
    };

    const auto readBool = [L, TABLE](const char* name, std::optional<bool>& target) -> bool {
        lua_getfield(L, TABLE, name);
        if (lua_isnil(L, -1)) {
            lua_pop(L, 1);
            return true;
        }

        if (!lua_isboolean(L, -1)) {
            lua_pop(L, 1);
            luaL_error(L, "configure: %s must be a boolean", name);
            return false;
        }

        target = lua_toboolean(L, -1);
        lua_pop(L, 1);
        return true;
    };

    if (!readInt("gesture_distance", g_luaConfig.gestureDistance) || !readFloat("scale", g_luaConfig.scale) ||
        !readInt("workspace_gap", g_luaConfig.workspaceGap) || !readInt("wallpaper", g_luaConfig.wallpaper) || !readBool("blur", g_luaConfig.blur))
        return 0;

    lua_getfield(L, TABLE, "shadow");
    if (lua_istable(L, -1)) {
        const int SHADOW = lua_absindex(L, -1);

        lua_getfield(L, SHADOW, "enabled");
        if (!lua_isnil(L, -1)) {
            if (!lua_isboolean(L, -1))
                return luaL_error(L, "configure: shadow.enabled must be a boolean");
            g_luaConfig.shadowEnabled = lua_toboolean(L, -1);
        }
        lua_pop(L, 1);

        lua_getfield(L, SHADOW, "range");
        if (!lua_isnil(L, -1)) {
            if (!lua_isinteger(L, -1))
                return luaL_error(L, "configure: shadow.range must be an integer");
            g_luaConfig.shadowRange = sc<int>(lua_tointeger(L, -1));
        }
        lua_pop(L, 1);

        lua_getfield(L, SHADOW, "render_power");
        if (!lua_isnil(L, -1)) {
            if (!lua_isinteger(L, -1))
                return luaL_error(L, "configure: shadow.render_power must be an integer");
            g_luaConfig.shadowRenderPower = sc<int>(lua_tointeger(L, -1));
        }
        lua_pop(L, 1);

        lua_getfield(L, SHADOW, "color");
        if (!lua_isnil(L, -1)) {
            if (!lua_isinteger(L, -1))
                return luaL_error(L, "configure: shadow.color must be an integer");
            g_luaConfig.shadowColor = sc<int64_t>(lua_tointeger(L, -1));
        }
        lua_pop(L, 1);
    } else if (!lua_isnil(L, -1))
        return luaL_error(L, "configure: shadow must be a table");
    lua_pop(L, 1);

    return 0;
}

}

namespace ScrollOverview::Config {

const SScrollOverviewLuaConfig& lua() {
    return g_luaConfig;
}

void registerLua(TOverviewDispatcher dispatcher) {
    if (::Config::mgr()->type() != ::Config::CONFIG_LUA)
        return;

    g_overviewDispatcher = dispatcher;
    HyprlandAPI::addLuaFunction(SCROLLOVERVIEW_HANDLE, "scrolloverview", "overview", ::overviewLua);
    HyprlandAPI::addLuaFunction(SCROLLOVERVIEW_HANDLE, "scrolloverview", "configure", ::configureLua);
}

void registerLegacy() {
    HyprlandAPI::addConfigValue(SCROLLOVERVIEW_HANDLE, "plugin:scrolloverview:gesture_distance", Hyprlang::INT{200});
    HyprlandAPI::addConfigValue(SCROLLOVERVIEW_HANDLE, "plugin:scrolloverview:scale", Hyprlang::FLOAT{0.5F});
    HyprlandAPI::addConfigValue(SCROLLOVERVIEW_HANDLE, "plugin:scrolloverview:workspace_gap", Hyprlang::INT{0});
    HyprlandAPI::addConfigValue(SCROLLOVERVIEW_HANDLE, "plugin:scrolloverview:wallpaper", Hyprlang::INT{0});
    HyprlandAPI::addConfigValue(SCROLLOVERVIEW_HANDLE, "plugin:scrolloverview:blur", Hyprlang::INT{0});
    HyprlandAPI::addConfigValue(SCROLLOVERVIEW_HANDLE, "plugin:scrolloverview:shadow:enabled", Hyprlang::INT{0});
    HyprlandAPI::addConfigValue(SCROLLOVERVIEW_HANDLE, "plugin:scrolloverview:shadow:range", Hyprlang::INT{-1});
    HyprlandAPI::addConfigValue(SCROLLOVERVIEW_HANDLE, "plugin:scrolloverview:shadow:render_power", Hyprlang::INT{-1});
    HyprlandAPI::addConfigValue(SCROLLOVERVIEW_HANDLE, "plugin:scrolloverview:shadow:color", Hyprlang::INT{-1});
}

int getGestureDistance() {
    if (g_luaConfig.gestureDistance)
        return std::max<int>(1, *g_luaConfig.gestureDistance);
    if (::Config::mgr()->type() == ::Config::CONFIG_LUA)
        return 200;

    return std::max<int>(1, getValue<int>("plugin:scrolloverview:gesture_distance"));
}

float getScale() {
    if (g_luaConfig.scale)
        return std::clamp(*g_luaConfig.scale, 0.1F, 0.9F);
    if (::Config::mgr()->type() == ::Config::CONFIG_LUA)
        return 0.5F;

    return std::clamp(getValue<float>("plugin:scrolloverview:scale"), 0.1F, 0.9F);
}

int getWorkspaceGap() {
    if (g_luaConfig.workspaceGap)
        return std::max<int>(0, *g_luaConfig.workspaceGap);
    if (::Config::mgr()->type() == ::Config::CONFIG_LUA)
        return 0;

    return std::max<int>(0, getValue<int>("plugin:scrolloverview:workspace_gap"));
}

int getWallpaperMode() {
    if (g_luaConfig.wallpaper)
        return std::clamp<int>(*g_luaConfig.wallpaper, 0, 2);
    if (::Config::mgr()->type() == ::Config::CONFIG_LUA)
        return 0;

    return std::clamp<int>(getValue<int>("plugin:scrolloverview:wallpaper"), 0, 2);
}

bool getBlur() {
    if (g_luaConfig.blur)
        return *g_luaConfig.blur;
    if (::Config::mgr()->type() == ::Config::CONFIG_LUA)
        return false;

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
    return g_luaConfig.shadowEnabled ? (*g_luaConfig.shadowEnabled ? 1 : 0) : getLegacyPluginIntValueOr("plugin:scrolloverview:shadow:enabled", 0);
}

int getShadowRange() {
    if (g_luaConfig.shadowRange)
        return *g_luaConfig.shadowRange;

    return getLegacyPluginIntValueOr("plugin:scrolloverview:shadow:range", -1);
}

int getShadowRenderPower() {
    if (g_luaConfig.shadowRenderPower)
        return *g_luaConfig.shadowRenderPower;

    return getLegacyPluginIntValueOr("plugin:scrolloverview:shadow:render_power", -1);
}

int64_t getShadowColor() {
    if (g_luaConfig.shadowColor)
        return *g_luaConfig.shadowColor;

    return getLegacyPluginIntValueOr("plugin:scrolloverview:shadow:color", -1);
}

}
