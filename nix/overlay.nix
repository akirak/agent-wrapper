packagesForSystems: final: prev:
let
  inherit (prev.hostPlatform.stdenv) system;
  inherit (final) lib;
in
{
  agent-wrapper = lib.extendDerivation true {
    writeConfigFile = final.writers.writeTOML;
    wrapCommand = final.callPackage ./wrapper.nix { };
  } packagesForSystems.${system}.default;
}
