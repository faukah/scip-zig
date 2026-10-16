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

      # the zig release scip-zig parses source of and is built with
      zigVersion = "0.17";
      zigFor = pkgs: pkgs.zigPackages.${zigVersion};
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          scip-zig = pkgs.callPackage ./nix/package.nix { zig = zigFor pkgs; };
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
        in
        {
          default = pkgs.callPackage ./nix/shell.nix {
            zig = zigFor pkgs;
            scip = scipFor pkgs;
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          inherit (self.packages.${system}) scip-zig;
        in
        {
          inherit scip-zig;
          smoke = pkgs.callPackage ./nix/smoke.nix {
            inherit scip-zig;
            scip = scipFor pkgs;
          };
          fmt =
            pkgs.runCommand "scip-zig-fmt-check"
              {
                nativeBuildInputs = [
                  (zigFor pkgs)
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
            (zigFor pkgs)
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
