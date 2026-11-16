# source me: build against the private Hyprland 0.57.2 in ~/sdk/hl057
P=$HOME/sdk/hl057
export PKG_CONFIG_PATH=$P/lib64/pkgconfig:$P/share/pkgconfig:$P/usr/lib64/pkgconfig:$P/usr/share/pkgconfig
export LD_LIBRARY_PATH=$P/lib64 HYPRLAND_BIN=$P/bin/Hyprland PATH=$P/bin:$PATH HYPRDRIVE_YES=1
