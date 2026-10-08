# SPDX-License-Identifier: EUPL-1.2
{
  lib,
  mkShellNoCC,
  zig,
  zls,
  scip,
  nixfmt,
}:
mkShellNoCC {
  packages = [
    zig
    scip
    nixfmt
  ]
  # zls has to match the compiler's minor version to be useful
  ++ lib.optional (lib.versions.majorMinor zls.version == lib.versions.majorMinor zig.version) zls;
}
