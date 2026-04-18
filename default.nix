{
  lib,
  hyprland,
  hyprlandPlugins,
}:
hyprlandPlugins.mkHyprlandPlugin {
  pluginName = "scrolloverview";
  version = "0.1";
  src = ./.;

  inherit (hyprland) nativeBuildInputs;

  meta = with lib; {
    homepage = "https://github.com/hyprwm/hyprland-plugins/tree/main/scrolloverview";
    description = "Hyprland workspaces overview plugin";
    license = licenses.bsd3;
    platforms = platforms.linux;
  };
}
