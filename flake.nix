# SPDX-License-Identifier: EUPL-1.2
{
  description = "SCIP indexer for Zig";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      pkgsFor = system: nixpkgs.legacyPackages.${system};
      scipFor = pkgs: pkgs.callPackage ./nix/scip.nix { };

      zigVersions = {
        "0_16" = "0.16";
        "0_17" = "0.17";
      };
      defaultZig = "0_17";
      # `zig fmt` migrates source to its own release, e.g. 0.17 rewrites
      # `@intFromEnum` to `@backingInt`, so format with the oldest one
      fmtZig = "0_16";

      zigFor = pkgs: suffix: pkgs.zigPackages.${zigVersions.${suffix}};
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          builds = lib.mapAttrs' (
            suffix: _:
            lib.nameValuePair "scip-zig_${suffix}" (
              pkgs.callPackage ./nix/package.nix { zig = zigFor pkgs suffix; }
            )
          ) zigVersions;
        in
        builds
        // {
          scip-zig = builds."scip-zig_${defaultZig}";
          default = self.packages.${system}.scip-zig;
        }
      );

      apps = forAllSystems (
        system:
        let
          scip-zig = self.packages.${system}.scip-zig;
        in
        {
          default = {
            type = "app";
            program = lib.getExe scip-zig;
            inherit (scip-zig) meta;
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          shells = lib.mapAttrs' (
            suffix: _:
            lib.nameValuePair "zig_${suffix}" (
              pkgs.callPackage ./nix/shell.nix {
                zig = zigFor pkgs suffix;
                scip = scipFor pkgs;
              }
            )
          ) zigVersions;
        in
        shells
        // {
          default = shells."zig_${defaultZig}";
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          builds = lib.filterAttrs (name: _: lib.hasPrefix "scip-zig_" name) self.packages.${system};
          smoke = lib.mapAttrs' (
            name: scip-zig:
            lib.nameValuePair "smoke-${lib.removePrefix "scip-zig_" name}" (
              pkgs.callPackage ./nix/smoke.nix {
                inherit scip-zig;
                scip = scipFor pkgs;
              }
            )
          ) builds;
        in
        builds
        // smoke
        // {
          fmt =
            pkgs.runCommand "scip-zig-fmt-check"
              {
                nativeBuildInputs = [
                  (zigFor pkgs fmtZig)
                  pkgs.nixfmt
                ];
                src = ./.;
              }
              ''
                cd $src
                zig fmt --check build.zig build.zig.zon src
                find . -name '*.nix' -exec nixfmt --check {} +
                touch $out
              '';
        }
      );

      # `nix fmt`
      formatter = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        pkgs.writeShellApplication {
          name = "scip-zig-fmt";
          runtimeInputs = [
            (zigFor pkgs fmtZig)
            pkgs.nixfmt
            pkgs.findutils
          ];
          text = ''
            zig fmt build.zig build.zig.zon src
            find . -name '*.nix' -not -path './.zig-cache/*' -exec nixfmt {} +
          '';
        }
      );
    };
}
