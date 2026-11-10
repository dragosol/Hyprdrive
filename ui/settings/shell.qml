//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic
//@ pragma Env QT_WAYLAND_DISABLE_WINDOWDECORATION=1

// HYPRDRIVE SETTINGS -- the standalone app (native port B1). On Omarchy the
// settings are the dragos.hyprdrive bar panel; on plain Hyprland there is no
// shell to host one, so this is a window of its own, run by `qs -p` from the
// `hyprdrive-settings` launcher. The page itself is SettingsPage.qml (the
// panel's renderer, without the Omarchy shell); this file is only the window,
// the single-instance IPC, and the deep links.
//
// ONE INSTANCE, NOTHING RESIDENT. Closing the window quits the process, as
// closing the Omarchy panel unloads it. A second launch does not start a
// second app: the launcher calls this one's IPC (target hyprdrive-settings)
// and only starts qs when nobody answers.
//
// MATCHED BY TITLE. Quickshell's Wayland app_id is org.quickshell for every
// window it makes (0.3 has no override), so the window rule in
// config/hyprdrive/36-settings-app.lua matches the title, which is set before
// the first commit.
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: shell

  // What SettingsPage.qml calls its host (Panel.qml's role in the shell).
  readonly property bool opened: true
  // Deep links: the launcher's --icons / --pane arrive as the environment on a
  // fresh start, and through the IPC below when the window is already up.
  property string pendingIconApp: Quickshell.env("HYPRDRIVE_SETTINGS_ICONS") || ""
  property string pendingPane: Quickshell.env("HYPRDRIVE_SETTINGS_PANE") || ""

  function close() { Qt.quit() }

  IpcHandler {
    target: "hyprdrive-settings"
    function open(): void { win.raise() }
    function show(): void { win.raise() }
    function close(): void { shell.close() }
    function hide(): void { shell.close() }
    function toggle(): void { shell.close() }
    function pane(id: string): void { shell.pendingPane = id; win.raise() }
    // The dock's Get Info -> App Icon: Icons, with this app chosen.
    function icons(appId: string): void { shell.pendingIconApp = appId; win.raise() }
  }

  FloatingWindow {
    id: win
    title: "Hyprdrive Settings"
    implicitWidth: 1120
    implicitHeight: 800
    minimumSize: Qt.size(860, 560)
    color: page.bg
    visible: true

    // Closed by the compositor (killactive, the window's close): quit, so a
    // closed settings app holds no memory, like the closed panel.
    onVisibleChanged: if (!visible) Qt.quit()
    onClosed: Qt.quit()

    // Hyprland focuses a window that asks for activation; a re-launch should
    // bring this one forward rather than leave it behind whatever was on top.
    function raise() {
      Quickshell.execDetached(["hyprctl", "dispatch", "focuswindow", "title:^(Hyprdrive Settings)$"])
    }

    SettingsPage {
      id: page
      anchors.fill: parent
      host: shell
      focus: true
    }
  }
}
