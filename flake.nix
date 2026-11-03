{
  inputs = {
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # Configure a binary cache for your executable(s).
  # nixConfig = {
  #   extra-substituters =
  #     [
  #     ];
  #   extra-trusted-public-keys =
  #     [
  #     ];
  # };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      eachSystem =
        f:
        lib.genAttrs nixpkgs.lib.systems.flakeExposed (system: f system nixpkgs.legacyPackages.${system});

      agentWrapper =
        pkgs:
        pkgs.buildGoModule {
          pname = "agent-wrapper";
          version = "0.1.0";
          src = ./.;
          vendorHash = "sha256-pbA/AlBz3cQYRTMnQ/qBPcinYOKokrBLNhkbRTq54gE=";
          meta = {
            description = "Wrapper for coding agent commands with preconditions, a bubblewrap sandbox, and file-based environment variables";
            mainProgram = "agent-wrapper";
            license = lib.licenses.mit;
          };
        };

      treefmtEval = eachSystem (_system: pkgs: treefmt-nix.lib.evalModule pkgs ./treefmt.nix);
    in
    {
      packages = eachSystem (
        system: pkgs: {
          agent-wrapper = agentWrapper pkgs;
          default = agentWrapper pkgs;
        }
      );

      devShells = eachSystem (
        system: pkgs: {
          default = pkgs.mkShell {
            packages = [
              pkgs.go
              pkgs.gopls
            ];
          };
        }
      );

      formatter = eachSystem (system: pkgs: treefmtEval.${system}.config.build.wrapper);

      checks = eachSystem (
        system: pkgs: {
          treefmt = treefmtEval.${system}.config.build.check self;
        }
      );
    };
}
