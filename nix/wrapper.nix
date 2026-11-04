{
  lib,
  writers,
  symlinkJoin,
  writeShellScript,
  agent-wrapper,
}:
{
  config ? null,
  preamble ? null,
}:
package:
let
  mainProgram = (package.meta or { }).mainProgram or (lib.getName package);

  wrappedProgram = writeShellScript mainProgram ''
    ${lib.optionalString (preamble != null) preamble}
    exec ${lib.getExe agent-wrapper} ${
      lib.optionalString (
        config != null
      ) "-f ${lib.escapeShellArg (writers.writeTOML "config.toml" config)}"
    } ${lib.escapeShellArg "${package}/bin/${mainProgram}"} "$@"
  '';
in
symlinkJoin {
  inherit (package) name;
  paths = [ package ];

  postBuild = ''
    unlink $out/bin/${mainProgram}
    ln -s ${wrappedProgram} $out/bin/${mainProgram}
  '';

  meta = package.meta or { };
}
