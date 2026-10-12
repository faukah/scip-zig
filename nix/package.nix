# SPDX-License-Identifier: EUPL-1.2
{
  lib,
  stdenv,
  zig,
}:
let
  zon = builtins.readFile ../build.zig.zon;
  version = builtins.head (builtins.match ''.*\.version = "([^"]+)".*'' zon);
in
stdenv.mkDerivation {
  pname = "scip-zig";
  inherit version;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../src
    ];
  };

  nativeBuildInputs = [ zig.hook ];

  # std is installed alongside; zig itself, LLVM and all, must not be needed to run
  disallowedReferences = [ zig ];

  # several releases can share a PATH, picked by the zig version a project wants
  postInstall = ''
    ln -s scip-zig $out/bin/scip-zig-${lib.versions.majorMinor zig.version}
  '';

  passthru = { inherit zig; };

  meta = {
    description = "SCIP indexer for Zig ${zig.version} source code";
    license = lib.licenses.eupl12;
    mainProgram = "scip-zig";
    inherit (zig.meta) platforms;
  };
}
