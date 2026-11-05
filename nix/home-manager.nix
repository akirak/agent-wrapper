packagesForSystems:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.agent-wrapper;
  tomlFormat = pkgs.formats.toml { };
in
{
  options.programs.agent-wrapper = {
    enable = lib.mkEnableOption "agent-wrapper";

    package = lib.mkOption {
      type = lib.types.package;
      default = packagesForSystems.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "inputs.agent-wrapper.packages.\${pkgs.stdenv.hostPlatform.system}.default";
      description = "The agent-wrapper package to install.";
    };

    settings = lib.mkOption {
      type = lib.types.submodule {
        options = {
          preconditions = {
            check_environment = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Require AGENTS_ALLOW_RUN=1 and a working directory under one
                of the allowed prefixes before running the command.
              '';
            };

            allowed_working_directory_prefixes = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "/git" ];
              description = ''
                Allowed absolute working directory prefixes. Must be non-empty
                when check_environment is enabled.
              '';
            };
          };

          sandbox.bubblewrap = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.submodule {
                options.arguments = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  example = [
                    "--bind"
                    "$HOME"
                    "$HOME"
                    "--unshare-all"
                  ];
                  description = ''
                    Arguments passed to Bubblewrap before the wrapped command.
                    Environment variable references ($NAME or ''${NAME}) anywhere
                    in each argument are expanded at runtime. Unset variables
                    expand to an empty string; no shell evaluation is performed.
                  '';
                };

                options.extra_arguments = lib.mkOption {
                  type = lib.types.attrsOf (lib.types.listOf lib.types.str);
                  default = { };
                  example = {
                    pi = [
                      "--bind-try"
                      "$HOME/.pi"
                      "$HOME/.pi"
                    ];
                  };
                  description = ''
                    Extra arguments passed to Bubblewrap when the wrapped
                    command's executable name (without directory) matches the
                    attribute name. Appended after the regular arguments and
                    subject to the same environment variable expansion.
                  '';
                };
              }
            );
            default = null;
            description = ''
              Bubblewrap sandbox configuration. Set to null to disable the
              sandbox. When configured, bwrap must be available in PATH on Linux;
              other Unix-like platforms ignore this setting with a warning.
            '';
          };

          environment = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule {
                options.file = lib.mkOption {
                  type = lib.types.str;
                  example = "/run/secrets/anthropic-api-key";
                  description = ''
                    Runtime path to a file whose trimmed contents become the
                    environment variable's value. A missing file unsets the
                    variable. The referenced file is read at runtime rather
                    than copied into the Nix store.
                  '';
                };
              }
            );
            default = { };
            description = "Environment variables loaded from files before running the command.";
          };
        };
      };
      default = { };
      example = lib.literalExpression ''
        {
          preconditions = {
            check_environment = true;
            allowed_working_directory_prefixes = [ "/git" ];
          };
          environment.ANTHROPIC_API_KEY.file = "/run/secrets/anthropic-api-key";
        }
      '';
      description = ''
        Configuration written to {file}`$XDG_CONFIG_HOME/agent-wrapper/config.toml`.
        The generated file is stored in the Nix store; reference secret files
        through the environment settings instead of including secret values.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
    xdg.configFile."agent-wrapper/config.toml".source =
      tomlFormat.generate "agent-wrapper-config.toml"
        (lib.filterAttrsRecursive (_: value: value != null) cfg.settings);
  };
}
