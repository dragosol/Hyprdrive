// See CpuPulse.hpp.
#include "CpuPulse.hpp"
#include "Config.hpp"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <set>
#include <unistd.h>
#include <unordered_map>

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/state/MonitorState.hpp>

namespace ScrollOverview::CpuPulse {
    namespace {
        using Clock = std::chrono::steady_clock;

        constexpr int   SAMPLE_MS = 1000;
        constexpr float PERIOD_S  = 1.2F; // one breath of the pulse

        wl_event_source*                            g_timer = nullptr;
        bool                                        g_down  = false;
        std::unordered_map<int, unsigned long long> g_lastTicks;
        Clock::time_point                           g_lastAt{};
        std::unordered_map<int, float>              g_tree; // pid -> % of one core, itself + descendants
        std::set<int>                               g_busy; // window pids over the threshold

        bool enabled() {
            static auto& VAL = Config::valueRef<Hyprlang::INT>("plugin:hyprdrive:dock:cpu_pulse");
            return *VAL != 0;
        }
        float threshold() {
            static auto& VAL = Config::valueRef<Hyprlang::INT>("plugin:hyprdrive:dock:cpu_pulse_threshold");
            return std::max(1.F, sc<float>(*VAL));
        }

        // /proc/PID/stat: the name is in parentheses and may hold spaces, so
        // the fields are read after the LAST ')'.
        bool readStat(int pid, int& ppid, unsigned long long& ticks) {
            char path[64];
            std::snprintf(path, sizeof(path), "/proc/%d/stat", pid);
            FILE* f = std::fopen(path, "re");
            if (!f)
                return false;
            char   buf[1024];
            size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
            std::fclose(f);
            buf[n]           = '\0';
            const char* rest = std::strrchr(buf, ')');
            if (!rest)
                return false;
            // state ppid pgrp session tty tpgid flags minflt cminflt majflt cmajflt utime stime
            char               state = 0;
            unsigned long long utime = 0, stime = 0;
            if (std::sscanf(rest + 1, " %c %d %*d %*d %*d %*d %*u %*u %*u %*u %*u %llu %llu", &state, &ppid, &utime, &stime) != 4)
                return false;
            ticks = utime + stime;
            return true;
        }

        void sample() {
            const auto NOW = Clock::now();
            const double DT = g_lastAt == Clock::time_point{} ? 0.0 : std::chrono::duration<double>(NOW - g_lastAt).count();
            g_lastAt        = NOW;
            const double HZ = std::max(1L, sysconf(_SC_CLK_TCK));

            std::unordered_map<int, unsigned long long> ticks;
            std::unordered_map<int, float>              own;
            std::unordered_multimap<int, int>           children;
            if (DIR* d = opendir("/proc")) {
                while (const dirent* e = readdir(d)) {
                    char*     end = nullptr;
                    const int PID = sc<int>(std::strtol(e->d_name, &end, 10));
                    if (PID <= 0 || !end || *end)
                        continue;
                    int                ppid = 0;
                    unsigned long long t    = 0;
                    if (!readStat(PID, ppid, t))
                        continue;
                    ticks[PID] = t;
                    children.emplace(ppid, PID);
                    if (const auto IT = g_lastTicks.find(PID); IT != g_lastTicks.end() && DT > 0.05 && t >= IT->second)
                        own[PID] = sc<float>((t - IT->second) / (HZ * DT) * 100.0);
                }
                closedir(d);
            }
            g_lastTicks = std::move(ticks);

            // An app's load: its own process tree, summed once per pid.
            g_tree.clear();
            std::set<int> busy;
            const float   LIMIT = threshold();
            for (const auto& W : Desktop::windowState()->windows()) {
                if (!W || !W->m_isMapped)
                    continue;
                const int ROOT = sc<int>(W->getPID());
                if (ROOT <= 0 || g_tree.contains(ROOT))
                    continue;
                float            sum = 0.F;
                std::vector<int> stack{ROOT};
                std::set<int>    seen;
                while (!stack.empty()) {
                    const int P = stack.back();
                    stack.pop_back();
                    if (!seen.insert(P).second)
                        continue;
                    if (const auto IT = own.find(P); IT != own.end())
                        sum += IT->second;
                    const auto [A, B] = children.equal_range(P);
                    for (auto it = A; it != B; ++it)
                        stack.push_back(it->second);
                }
                g_tree[ROOT] = sum;
                if (sum >= LIMIT)
                    busy.insert(ROOT);
            }

            // Something started or stopped pulsing: one repaint starts or ends
            // it (the dock's own pump keeps a pulse going -- Dock::needsFramesReason).
            if (busy != g_busy) {
                g_busy = std::move(busy);
                for (const auto& M : State::monitorState()->monitors())
                    if (M && M->m_enabled)
                        g_pHyprRenderer->damageMonitor(M);
            }
        }

        int tick(void*) {
            if (g_down)
                return 0;
            if (enabled())
                sample();
            else if (!g_busy.empty() || !g_lastTicks.empty()) {
                g_busy.clear();
                g_tree.clear();
                g_lastTicks.clear();
                g_lastAt = {};
            }
            if (g_timer)
                wl_event_source_timer_update(g_timer, SAMPLE_MS);
            return 0;
        }
    }

    void init() {
        if (g_timer || !g_pCompositor)
            return;
        g_down  = false;
        g_timer = wl_event_loop_add_timer(g_pCompositor->m_wlEventLoop, tick, nullptr);
        if (g_timer)
            wl_event_source_timer_update(g_timer, SAMPLE_MS);
    }

    void shutdown() {
        g_down = true;
        if (g_timer)
            wl_event_source_remove(g_timer);
        g_timer = nullptr;
        g_busy.clear();
        g_tree.clear();
        g_lastTicks.clear();
    }

    bool anyBusy() {
        return enabled() && !g_busy.empty();
    }

    float pulseFor(const std::vector<PHLWINDOW>& windows) {
        if (g_busy.empty() || !enabled())
            return 0.F;
        bool busy = false;
        for (const auto& W : windows)
            if (W && g_busy.contains(sc<int>(W->getPID()))) {
                busy = true;
                break;
            }
        if (!busy)
            return 0.F;
        const double T = std::chrono::duration<double>(Clock::now().time_since_epoch()).count();
        return sc<float>(0.5 - 0.5 * std::cos(2.0 * M_PI * std::fmod(T, PERIOD_S) / PERIOD_S));
    }
}
