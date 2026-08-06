#include "Minimize.hpp"

#include <algorithm>
#include <sstream>
#include <string>

#define private public
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/GlobalWindowController.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>
#undef private

namespace ScrollOverview::Minimize {

namespace {

struct SEntry {
    PHLWINDOWREF window;
    WORKSPACEID  workspace = WORKSPACE_INVALID;
    std::string  workspaceName;
    MONITORID    monitor = MONITOR_INVALID;
    CBox         box;
    bool         floating = false;
};

std::vector<SEntry> g_entries;

// The workspace tracker holds only weak refs (see ensureNoWorkspaceGaps), so
// this strong ref is what keeps the stash alive while it is empty.
PHLWORKSPACE g_stash;

constexpr const char* STASH_NAME = "special:minimized";

// A special workspace that is never shown keeps its windows MAPPED, which is
// the whole reason the spec picks one: an unmapped window cannot be previewed
// live (X25).
PHLWORKSPACE stash(PHLMONITOR monitor) {
    if (g_stash)
        return g_stash;

    for (const auto& w : State::workspaceState()->workspaces()) {
        const auto WORKSPACE = w.lock();
        if (WORKSPACE && WORKSPACE->m_name == STASH_NAME) {
            g_stash = WORKSPACE;
            return g_stash;
        }
    }

    if (!monitor)
        return nullptr;

    g_stash = State::workspaceState()->create(State::workspaceState()->newSpecialID(), monitor->m_id, STASH_NAME);
    return g_stash;
}

PHLWORKSPACE workspaceByID(WORKSPACEID id) {
    for (const auto& w : State::workspaceState()->workspaces()) {
        const auto WORKSPACE = w.lock();
        if (WORKSPACE && WORKSPACE->m_id == id)
            return WORKSPACE;
    }

    return nullptr;
}

std::vector<SEntry>::iterator entryFor(PHLWINDOW window) {
    return std::ranges::find_if(g_entries, [&window](const auto& e) { return e.window.lock() == window; });
}

void dropDeadEntries() {
    std::erase_if(g_entries, [](const auto& e) { return !e.window.lock(); });
}

}

bool isMinimized(PHLWINDOW window) {
    return window && entryFor(window) != g_entries.end();
}

WORKSPACEID originalWorkspace(PHLWINDOW window) {
    if (!window)
        return WORKSPACE_INVALID;

    const auto IT = entryFor(window);
    return IT == g_entries.end() ? WORKSPACE_INVALID : IT->workspace;
}

std::vector<PHLWINDOW> minimized() {
    dropDeadEntries();

    std::vector<PHLWINDOW> out;
    for (const auto& e : g_entries)
        out.emplace_back(e.window.lock());

    return out;
}

bool minimize(PHLWINDOW window) {
    dropDeadEntries();

    if (!window || isMinimized(window))
        return false;

    const auto WORKSPACE = window->m_workspace;
    const auto TARGET    = window->layoutTarget();
    if (!WORKSPACE || !TARGET || WORKSPACE->m_isSpecialWorkspace)
        return false;

    const auto STASHWS = stash(window->m_monitor.lock());
    if (!STASHWS)
        return false;

    // X41/X42: a workspace move is exactly where geometry gets destroyed
    // silently, so capture the real box first and put it back on restore.
    g_entries.emplace_back(SEntry{window, WORKSPACE->m_id, WORKSPACE->m_name, WORKSPACE->m_monitor ? WORKSPACE->m_monitor->m_id : MONITOR_INVALID,
                                  TARGET->position(), window->m_isFloating});

    Desktop::globalWindowController()->moveWindowToWorkspace(window, STASHWS);

    // A stashed window must not keep the keyboard. Measured 2026-08-03 by X33's
    // rig: minimize left focus on the window it had just taken off screen, so
    // typing went to something invisible and the dock read the app as still
    // focused -- which is the test `cycle-windows` branches on. Hand the focus
    // to whatever is left on the workspace it came from.
    if (Desktop::focusState()->isWindowActive(window)) {
        PHLWINDOW next;
        for (const auto& CANDIDATE : Desktop::windowState()->windows()) {
            if (CANDIDATE != window && CANDIDATE->m_isMapped && CANDIDATE->m_workspace == WORKSPACE)
                next = CANDIDATE;
        }

        if (next)
            Desktop::focusState()->fullWindowFocus(next, Desktop::FOCUS_REASON_OTHER);
        else
            Desktop::focusState()->resetWindowFocus();
    }

    return true;
}

bool restore(PHLWINDOW window) {
    dropDeadEntries();

    if (!window)
        return false;

    const auto IT = entryFor(window);
    if (IT == g_entries.end())
        return false;

    const auto ENTRY = *IT;
    g_entries.erase(IT);

    // Minimizing the last window of a workspace lets Hyprland reap it the
    // moment the user looks away, and without this the window is stranded on
    // the stash with no way back. Measured: leave the workspace and it is gone.
    auto WORKSPACE = workspaceByID(ENTRY.workspace);
    if (!WORKSPACE)
        WORKSPACE = State::workspaceState()->create(ENTRY.workspace, ENTRY.monitor, ENTRY.workspaceName);

    if (!WORKSPACE)
        return false;

    Desktop::globalWindowController()->moveWindowToWorkspace(window, WORKSPACE);

    // ponytail: only floating windows own their box. A tiled window's geometry
    // belongs to the layout, and writing it back would fight the retile.
    if (ENTRY.floating && !ENTRY.box.empty()) {
        if (const auto TARGET = window->layoutTarget(); TARGET) {
            TARGET->setPositionGlobal(ENTRY.box);
            TARGET->warpPositionSize();
        }
    }

    if (const auto MONITOR = WORKSPACE->m_monitor.lock(); MONITOR && MONITOR->m_activeWorkspace != WORKSPACE)
        MONITOR->changeWorkspace(WORKSPACE, false, true, true);

    // X43: focus and stacking are two different things. A restored window that
    // is merely focused can come back underneath whatever was on top of it.
    Desktop::windowState()->raise(window);
    Desktop::focusState()->fullWindowFocus(window, Desktop::FOCUS_REASON_KEYBIND);

    return true;
}

}
