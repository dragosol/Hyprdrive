// See Integration.hpp (the API) and IntegrationRule.hpp (the rule).
#include "Integration.hpp"

#include "Compat.hpp"
#include "Config.hpp"
#include "globals.hpp"

#include <hyprland/src/plugins/PluginAPI.hpp>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <format>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

namespace ScrollOverview::Integration {
    namespace {
        constexpr const char* KEY = "plugin:hyprdrive:integration";

        // The cached answer. desktop and generation are atomics because
        // omarchy() is documented as callable from worker threads (the search
        // workers will be among the callers); the decision text is main-thread
        // only and documented so.
        std::atomic<int>      g_desktop{-1}; // -1 = never evaluated
        std::atomic<uint64_t> g_generation{0};
        SDecision             g_decision;
        SP<SHyprCtlCommand>   g_hyprctl;

        // `command -v omarchy` without a shell: every PATH entry, an executable
        // regular file. Hyprland reaps its own children (Omarchy's helpers.lua
        // says the same), so spawning `sh -c 'command -v'` from in here could
        // not even read the exit status; a stat per PATH entry is cheaper anyway.
        bool omarchyOnPath() {
            const char* PATH = std::getenv("PATH");
            if (!PATH || !*PATH)
                return false;
            std::string_view rest{PATH};
            while (true) {
                const auto       COLON = rest.find(':');
                std::string_view dir   = rest.substr(0, COLON);
                if (dir.empty())
                    dir = "."; // POSIX: an empty PATH element is the cwd
                const std::string CAND = std::string{dir} + "/omarchy";
                struct stat       st {};
                if (stat(CAND.c_str(), &st) == 0 && S_ISREG(st.st_mode) && access(CAND.c_str(), X_OK) == 0)
                    return true;
                if (COLON == std::string_view::npos)
                    return false;
                rest.remove_prefix(COLON + 1);
            }
        }

        // The same directory Config.cpp's omarchyTheme() reads colors.toml from:
        // $XDG_STATE_HOME/omarchy/current, else ~/.local/state/omarchy/current.
        // A symlink to a theme counts (stat follows it); a dangling one does not.
        bool omarchyState() {
            const char* const STATE = std::getenv("XDG_STATE_HOME");
            const char* const HOME  = std::getenv("HOME");
            const std::string PATH  = (STATE && *STATE) ? std::string{STATE} + "/omarchy/current" :
                                      (HOME && *HOME)   ? std::string{HOME} + "/.local/state/omarchy/current" :
                                                          std::string{};
            struct stat st {};
            return !PATH.empty() && stat(PATH.c_str(), &st) == 0;
        }

        // The key's value, or "" while it does not exist yet: reading a plugin
        // key before registerConfig() aborts Hyprland (Config.hpp), and the
        // whole point of omarchy() is that it is safe to ask from PLUGIN_INIT.
        std::string configValue() {
            if (!Config::g_pluginKeysRegistered)
                return {};
            return Config::getValue<std::string>(KEY);
        }

        std::string jsonEscape(std::string_view s) {
            std::string out;
            for (const char C : s) {
                if (C == '"' || C == '\\')
                    out += '\\';
                if (sc<unsigned char>(C) < 0x20)
                    out += std::format("\\u{:04x}", sc<int>(C));
                else
                    out += C;
            }
            return out;
        }

        void ensure() {
            if (g_desktop.load(std::memory_order_acquire) < 0)
                reevaluate();
        }
    }

    SProbe probe(std::string_view cfg) {
        SProbe p;
        const char* const NO  = std::getenv("HYPRDRIVE_NO_OMARCHY");
        const char* const ENV = std::getenv("HYPRDRIVE_INTEGRATION");
        p.noOmarchyEnv        = NO && std::string_view{NO} == "1";
        p.envValue            = ENV ? ENV : "";
        p.configValue         = std::string{cfg};
        p.omarchyOnPath       = omarchyOnPath();
        p.omarchyState        = omarchyState();
        return p;
    }

    void reevaluate() {
        auto       next = decide(probe(configValue()));
        const int  WAS  = g_desktop.load(std::memory_order_acquire);
        const bool FIRST = WAS < 0;
        const bool CHANGED = !FIRST && WAS != sc<int>(next.desktop);
        // Logged on the first answer and on every change, never on a reload
        // that changed nothing: one line per session in the normal case.
        if (FIRST || CHANGED || next.reason != g_decision.reason)
            std::fprintf(stderr, "[hyprdrive] integration: %s (%s: %s)\n", std::string{name(next.desktop)}.c_str(), std::string{name(next.source)}.c_str(),
                         next.reason.c_str());
        g_decision = std::move(next);
        g_desktop.store(sc<int>(g_decision.desktop), std::memory_order_release);
        if (FIRST || CHANGED)
            g_generation.fetch_add(1, std::memory_order_acq_rel);
    }

    bool omarchy() {
        return desktop() == EDesktop::Omarchy;
    }

    EDesktop desktop() {
        ensure();
        return sc<EDesktop>(g_desktop.load(std::memory_order_acquire));
    }

    const SDecision& decision() {
        ensure();
        return g_decision;
    }

    uint64_t generation() {
        ensure();
        return g_generation.load(std::memory_order_acquire);
    }

    int luaIntegration(lua_State* L) {
        // Fresh, not cached: mid-parse the cache is the PREVIOUS parse's answer,
        // and a fragment asking right after `plugin = { hyprdrive = {
        // integration = "none" } }` means this parse's value.
        const auto D = decide(probe(configValue()));
        lua_pushstring(L, std::string{name(D.desktop)}.c_str());
        lua_pushstring(L, D.reason.c_str());
        return 2;
    }

    void init() {
        reevaluate();
        g_hyprctl = HyprlandAPI::registerHyprCtlCommand(SCROLLOVERVIEW_HANDLE,
                                                        SHyprCtlCommand{
                                                            .name  = "hyprdrive-integration",
                                                            .exact = true,
                                                            .fn =
                                                                [](eHyprCtlOutputFormat format, std::string) -> std::string {
                                                                    const auto& D = decision();
                                                                    if (format == FORMAT_JSON)
                                                                        return std::format(R"({{"integration": "{}", "source": "{}", "reason": "{}"}})",
                                                                                           name(D.desktop), name(D.source), jsonEscape(D.reason));
                                                                    return std::format("{}\nsource: {}\nreason: {}\n", name(D.desktop), name(D.source), D.reason);
                                                                },
                                                        });
    }

    void shutdown() {
        if (g_hyprctl)
            HyprlandAPI::unregisterHyprCtlCommand(SCROLLOVERVIEW_HANDLE, g_hyprctl);
        g_hyprctl.reset();
    }
}
