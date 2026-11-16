#include "HyprCompat.hpp"
#include "FunctionHooks.hpp"

#include <hyprland/src/plugins/HookSystem.hpp>

namespace Hyprdrive::Compat {
    namespace {
        CFunctionHook*  g_invokeBindHook = nullptr;
        Keybinds::PBind g_currentBind;

        using TInvokeBind = Keybinds::SBindResult (*)(Keybinds::CKeybindManager*, const Keybinds::PBind&, bool, Keybinds::SPressedInput*);

        Keybinds::SBindResult hkInvokeBind(Keybinds::CKeybindManager* self, const Keybinds::PBind& bind, bool pressed, Keybinds::SPressedInput* pressedInput) {
            // Binds nest (a bind's action can invoke another): restore the outer one.
            auto outer  = std::exchange(g_currentBind, bind);
            auto result = rc<TInvokeBind>(g_invokeBindHook->m_original)(self, bind, pressed, pressedInput);
            g_currentBind = std::move(outer);
            return result;
        }
    }

    std::unordered_map<std::string, TOwnDispatcher>& ownDispatchers() {
        static std::unordered_map<std::string, TOwnDispatcher> table;
        return table;
    }

    std::optional<SDispatchResult> dispatchOwn(const std::string& name, std::string arg) {
        const auto IT = ownDispatchers().find(name);
        if (IT == ownDispatchers().end())
            return std::nullopt;
        return IT->second(std::move(arg));
    }

    std::optional<std::string> dispatchLua(const std::string& luaExpr) {
        if (!::Config::mgr() || ::Config::mgr()->type() != ::Config::CONFIG_LUA)
            return std::nullopt;
        const auto MGR = ::Config::Lua::mgr().lock();
        if (!MGR)
            return std::nullopt;
        return MGR->eval(std::format("return hl.dispatch({})", luaExpr));
    }

    bool hookInvokeBind() {
        if (g_invokeBindHook)
            return true;
        g_invokeBindHook = FunctionHooks::firstMatch("HyprCompat", "invokeBind", rc<void*>(hkInvokeBind), "CKeybindManager::invokeBind(");
        return g_invokeBindHook && g_invokeBindHook->hook();
    }

    Keybinds::PBind currentBind() {
        return g_currentBind;
    }
}
