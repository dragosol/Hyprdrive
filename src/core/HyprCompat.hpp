#pragma once
// Hyprland 0.57 port: the names Hyprdrive used on 0.56 that no longer exist.
// Workspace ids were one signed integer (special workspaces negative); 0.57 has
// a variant (numbered | special). Hyprdrive keeps its integer keys.
#include <hyprland/src/workspace/HLWorkspace.hpp>
#include <hyprland/src/workspace/SpecialWorkspace.hpp>
#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/desktop/view/window/WindowMetadata.hpp>
#include <hyprland/src/desktop/view/window/WindowGroupMembership.hpp>
#include <hyprland/src/desktop/view/window/WindowPresentation.hpp>
#include <hyprland/src/desktop/view/window/WindowBackend.hpp>
#include <hyprland/src/desktop/view/window/WindowEffectsController.hpp>
#include <hyprland/src/desktop/view/window/WindowFullscreenPolicy.hpp>
#include <hyprland/src/render/decorations/IHyprWindowDecoration.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/input/Keys.hpp>
#include <cstdint>
#include <functional>

using enum Input::eKeyboardModifiers;
using WORKSPACEID = int64_t;
inline constexpr WORKSPACEID WORKSPACE_INVALID = -1;

namespace Hyprdrive::Compat {
    inline bool isSpecial(const Workspace::CHLWorkspace* ws) {
        return ws && ws->type() == Workspace::eWorkspaceType::SPECIAL;
    }
    // A numbered workspace: its number. A special one: a stable negative id from
    // its name (0.56 handed out -99, -98, ... in creation order).
    inline WORKSPACEID id(const Workspace::CHLWorkspace* ws) {
        if (!ws)
            return WORKSPACE_INVALID;
        const auto ID = ws->id();
        if (const auto* N = std::get_if<Workspace::SWorkspaceNumberedID>(&ID))
            return sc<WORKSPACEID>(N->value);
        return -100 - sc<WORKSPACEID>(std::hash<std::string>{}(ws->addressableName()) % 1000000);
    }
    inline WORKSPACEID id(const PHLWORKSPACE& ws) { return id(ws.get()); }
    inline WORKSPACEID id(const PHLWORKSPACEREF& ws) { return id(ws.lock().get()); }
    template <typename T>
    bool isSpecial(const T& ws) { return isSpecial(ws.get()); }
    inline bool pinned(const PHLWINDOW& w) { return w && (w->m_state & Desktop::View::WINDOW_STATE_PINNED); }
    inline bool urgent(const PHLWINDOW& w) { return w && (w->m_hints & Desktop::View::WINDOW_HINT_URGENT); }
}
