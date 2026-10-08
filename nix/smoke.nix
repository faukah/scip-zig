# SPDX-License-Identifier: EUPL-1.2
# indexes scip-zig's own source and validates the result with the scip cli
{
  lib,
  runCommand,
  scip,
  scip-zig,
}:
runCommand "scip-zig-smoke-${scip-zig.passthru.zig.version}"
  {
    nativeBuildInputs = [
      scip
      scip-zig
    ];
    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [
        ../build.zig
        ../build.zig.zon
        ../src
      ];
    };
  }
  ''
    cp -r $src ./tree
    chmod -R +w ./tree
    cd ./tree
    scip-zig index --output index.scip
    scip lint index.scip
    scip stats --from index.scip > $out
  ''
