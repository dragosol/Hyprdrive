{
  lib,
  hyprland,
  hyprlandPlugins,
  lua5_4,
}:
hyprlandPlugins.mkHyprlandPlugin {
  pluginName = "scrolloverview";
  version = "0.1";
  src = ./.;

  inherit (hyprland) nativeBuildInputs;

  buildInputs = [ lua5_4 ];

  meta = {
    homepage = "https://github.com/hyprwm/hyprland-plugins/tree/main/scrolloverview";
    description = "Hyprland workspaces overview plugin";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
  };
}
