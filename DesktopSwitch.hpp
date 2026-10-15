#pragma once

#include <hyprland/src/devices/IPointer.hpp>
#include <hyprland/src/SharedDefs.hpp>

#include <string>

// DESKTOP SWITCHES (user, 2026-10-15). Two things about moving between desktops,
// both with the pure decisions in DesktopSwitchModel.hpp:
//
// SUPER+SCROLL. `hl.plugin.hyprdrive.desktop("next"|"prev")` (hyprlang
// `hyprdrive:desktop next|prev`) steps the focused monitor to the next or
// previous desktop BY NUMBER, empty ones included, clamped to
// 1..max(10, its highest desktop) without wrapping, one step per wheel notch.
// config/hyprdrive/50-desktop-scroll.lua binds it to <mods>+mouse_down /
// mouse_up while plugin:hyprdrive:binds:scroll_desktops is on (mods:
// binds:scroll_desktops_mods). With the overview open the wheel never reaches
// a bind (the overview takes it), so the overview itself treats a wheel with
// those modifiers held as "next/previous desktop card" whatever its own
// scroll action is (overviewWheelSwitchesDesktops), and the dispatcher, called
// from anywhere else while an overview is up, moves its desktop card too.
//
// ANIMATION BY CAUSE. animation:desktop_keyboard / animation:desktop_focus: a
// desktop switch made by a key or scroll bind, and one made by focus moving to
// a window on another desktop (xdg-activation, a dock click, a notification,
// `hyprctl dispatch focuswindow`), can each be made instant. The switch itself
// is Hyprland's (Animation::Workspace::startAnimation, hooked: `instant` is
// forced for a cause that is switched off). The cause is read off what is
// running when the switch starts -- a keybind (KeybindManager::m_currentKeybind),
// this dispatcher, or a focus call (CFocusState::fullWindowFocus,
// Config::Actions::focus, the dock's activation; hooked or scoped) -- see
// classify(). With the overview up, for special workspaces, and when
// Hyprland's workspaces animation is off anyway, nothing is changed.
namespace ScrollOverview::DesktopSwitch {
    // After Config::registerConfig() (the keys must exist), shutdown() at PLUGIN_EXIT.
    void init();
    void shutdown();

    // The `desktop` dispatcher: next | prev.
    SDispatchResult dispatch(std::string arg);

    // Overview input: is this wheel event Super+scroll (the configured
    // modifiers held, the feature on)? Then it moves the desktop card.
    bool overviewWheelSwitchesDesktops(const IPointer::SAxisEvent& e);

    // RAII: a desktop switch made inside this scope was caused by focus moving
    // (the dock's activation, which changes the desktop itself before focusing).
    struct CFocusScope {
        CFocusScope();
        ~CFocusScope();
        CFocusScope(const CFocusScope&)            = delete;
        CFocusScope& operator=(const CFocusScope&) = delete;
    };

    // `debug desktop`: the toggles, the last cause and decision, the notch bank.
    std::string debugReport();
}
