#pragma once

// THE SETTINGS, SEEN FROM THE COMPOSITOR (native port B1, A17).
//
// There are two settings surfaces and the compositor never draws either:
//   - on Omarchy, the dragos.hyprdrive bar panel inside the Omarchy shell
//     (omarchy-plugin/Panel.qml), reached over the shell's IPC;
//   - everywhere else, the standalone Quickshell app (settings/, launched by
//     `hyprdrive-settings`), which talks to the same bin/hdpanel and
//     bin/hdicons back ends the panel does.
// Which one is Integration's answer -- nothing here stat()s an Omarchy path of
// its own. Anything in the plugin that wants to send the user to a setting
// (the dock's Get Info -> App Icon row, the `settings` dispatcher) goes through
// open(), so the two desktops cannot drift apart.
//
// The app also needs the colours hyprdrive itself draws with, so it looks like
// the dock and the overview rather than like a stock Qt window. Those are
// DERIVED (Config.hpp: unset keys read Hyprland's live values, then Omarchy's
// colors.toml on Omarchy), and re-deriving them in QML would be a second copy of
// that logic to drift. So the plugin answers it:
//
//   hyprctl hyprdrive-theme      background/foreground/... one per line
//   hyprctl hyprdrive-theme -j   {"background": "#AARRGGBB", ..., "font": "...",
//                                 "rounding": N, "light": bool}
//
// Colours are Qt's #AARRGGBB, so QML can use them as they come.

#include <string>
#include <string_view>

#include <hyprland/src/SharedDefs.hpp>

namespace ScrollOverview::SettingsApp {

    // The standalone app's launcher, or "" when it is not installed: the first
    // executable `hyprdrive-settings` on PATH, then ~/.local/bin (a session
    // started without ~/.local/bin on PATH still finds a default-PREFIX
    // install). Re-checked on every call -- it is a handful of access() calls,
    // made when a menu opens, never per frame.
    std::string launcher();

    // Is there anything to open? Omarchy: always (its panel). Elsewhere: the
    // app is installed. The dock hides its App Icon row when this is false,
    // rather than offering a row that does nothing.
    bool available();

    // Open the settings. `pane` is a Schema.js section id ("" = wherever it
    // was); `iconApp` a desktop id, which opens the Icons section with that app
    // chosen and wins over `pane`. Returns false when nothing could be started.
    bool open(std::string_view pane = {}, std::string_view iconApp = {});

    // The `settings` dispatcher: open | toggle | close | pane <id> | icons <id>.
    // hl.plugin.hyprdrive.settings("pane dock"), or bind it:
    //   hl.bind("SUPER + COMMA", hl.plugin.hyprdrive.settings())
    SDispatchResult dispatch(std::string arg);

    // `hyprctl hyprdrive-theme` -- after registerConfig() (it reads keys).
    void init();
    void shutdown();
}
