{
    description = "A scrollable overview plugin for Hyprland with optional hyprbars integration";

    inputs = {
        nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
        hyprland.url = "github:hyprwm/Hyprland";
        flake-parts = {
            url = "github:hercules-ci/flake-parts";
            inputs.nixpkgs-lib.follows = "nixpkgs";
        };
    };

    outputs = inputs @ {
        self,
        nixpkgs,
        hyprland,
        flake-parts,
        ...
    }:
        flake-parts.lib.mkFlake {inherit inputs;} {
            systems = ["x86_64-linux"];

            perSystem = {
                config,
                pkgs,
                system,
                ...
            }: let
                hl = hyprland.packages.${system}.hyprland;
            in {
                packages.scrolloverview = pkgs.stdenv.mkDerivation {
                    pname = "hyprland-scroll-overview";
                    version = "0.1";
                    src = ./.;

                    inherit (hl) buildInputs;
                    nativeBuildInputs =
                        hl.nativeBuildInputs
                        ++ [
                            hl
                            pkgs.gcc14
                            pkgs.pkg-config
                            pkgs.lua5_4
                        ];

                    enableParallelBuilding = true;

                    buildPhase = ''
                        runHook preBuild
                        make all
                        runHook postBuild
                    '';

                    installPhase = ''
                        runHook preInstall
                        mkdir -p "$out/lib"
                        cp libscrolloverview.so "$out/lib/libscrolloverview.so"
                        runHook postInstall
                    '';
                };

                packages.default = config.packages.scrolloverview;

                devShells.default = pkgs.mkShell {
                    name = "hyprland-scroll-overview-dev";

                    inputsFrom = [config.packages.scrolloverview];

                    nativeBuildInputs = with pkgs; [
                        meson
                        clang-tools
                        ninja
                        pkg-config
                    ];
                };
            };
        };
}
