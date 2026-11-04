{
  inputs = {
    nixpkgs.url = "github:nix-ocaml/nix-overlays";
    # systems.url = "github:nix-systems/default";
  };

  outputs =
    {
      nixpkgs,
      self,
      ...
    }:
    let
      eachSystem =
        f:
        nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed (
          system:
          f system (
            nixpkgs.legacyPackages.${system}.extend (
              _self: super: {
                # You can set the OCaml version to a particular release. Also, you
                # may have to pin some packages to a particular revision if the
                # devshell fail to build. This should be resolved in the upstream.
                ocamlPackages = super.ocaml-ng.ocamlPackages_latest;
              }
            )
          )
        );
    in
    {
      packages = eachSystem (
        _system: pkgs: with pkgs; {
          default = ocamlPackages.buildDunePackage {
            pname = "agent-wrapper";
            version = "0.1";
            duneVersion = "3";
            src = self.outPath;

            buildInputs = with ocamlPackages; [
              cmdliner
              otoml
            ];
            doCheck = true;

            meta = {
              description = "Safety checks, secret loading, and sandboxing for coding agents";
              homepage = "https://github.com/akirak/agent-wrapper";
              license = lib.licenses.mit;
              platforms = lib.platforms.unix;
              mainProgram = "agent-wrapper";
            };
          };
        }
      );

      overlays.default = import ./nix/overlay.nix self.packages;

      homeManagerModules.default = import ./nix/home-manager.nix self.packages;

      checks = eachSystem (
        system: _pkgs: {
          build = self.packages.${system}.default;
        }
      );

      formatter = eachSystem (_system: pkgs: pkgs.treefmt.withConfig ./treefmt.nix);

      devShells = eachSystem (
        system: pkgs:
        {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.default ];
            packages = (
              with pkgs.ocamlPackages;
              [
                ocaml-lsp
                ocamlformat
                ocp-indent
              ]
            );
          };
        }
        // self.packages.${system}
      );
    };
}
