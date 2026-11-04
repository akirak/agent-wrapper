{ pkgs, ... }:
{
  runtimeInputs = [
    pkgs.ocamlPackages.ocamlformat
    pkgs.nixfmt
    pkgs.zizmor
  ];

  settings = {
    tree-root-file = "dune-project";
    excludes = [
      "_build/**"
      "_opam/**"
      ".direnv/**"
      "result/**"
    ];

    formatter = {
      ocamlformat = {
        command = "ocamlformat";
        options = [ "--inplace" ];
        includes = [
          "*.ml"
          "*.mli"
        ];
      };
      nixfmt = {
        command = "nixfmt";
        includes = [ "*.nix" ];
      };
      zizmor = {
        command = "zizmor";
        includes = [
          ".github/workflows/*.yml"
          ".github/workflows/*.yaml"
        ];
      };
    };
  };
}
