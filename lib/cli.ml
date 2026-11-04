let default_config_path environment =
  let directory =
    match Environment.get environment "XDG_CONFIG_HOME" with
    | "" -> (
      match Environment.get environment "HOME" with
      | "" ->
          System.fail
            "neither XDG_CONFIG_HOME nor HOME is set; specify a config file \
             with -f"
      | home -> Filename.concat home ".config" )
    | directory -> directory
  in
  System.clean_path (Filename.concat directory "agent-wrapper/config.toml")

let command =
  let open Cmdliner in
  let config =
    Arg.(
      last & opt_all string [""]
      & info ["f"; "config"] ~docv:"CONFIG_FILE"
          ~doc:
            "Read settings from $(docv). Defaults to \
             \\$XDG_CONFIG_HOME/agent-wrapper/config.toml, or \
             \\$HOME/.config/agent-wrapper/config.toml if XDG_CONFIG_HOME \
             is unset or empty." )
  in
  let command =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"COMMAND"
          ~doc:"Command (typically a coding agent) to execute." )
  in
  let args =
    Arg.(
      value & pos_right 0 string []
      & info [] ~docv:"ARGS"
          ~doc:"Arguments passed unchanged to $(i,COMMAND)." )
  in
  let doc = "Run a command with configured safety checks and environment" in
  let man =
    [ `S Manpage.s_description
    ; `P
        "Apply TOML-configured preconditions, file-backed environment \
         variables, and optional Bubblewrap sandboxing before executing \
         $(i,COMMAND). Wrapper options must precede $(i,COMMAND); all \
         arguments after it are passed through unchanged." ]
  in
  let exits =
    [ Cmd.Exit.info 0 ~doc:"The command succeeded, or help was requested."
    ; Cmd.Exit.info 1
        ~doc:"Configuration, precondition, environment, or sandbox error."
    ; Cmd.Exit.info 2 ~doc:"Invalid arguments or missing COMMAND."
    ; Cmd.Exit.info 125 ~doc:"The target command could not be executed." ]
  in
  Cmd.v
    (Cmd.info "agent-wrapper" ~doc ~man ~exits)
    Term.(
      const (fun config command args -> (config, command, args))
      $ config $ command $ args )

(* Cmdliner normally parses options anywhere. Insert -- before COMMAND to
   protect the target's arguments, and normalize legacy Go flag spellings.
   Option validation, value conversion, and help are handled by Cmdliner. *)
let rec protect_command = function
  | [] -> []
  | "--" :: _ as args -> args
  | ("-f" | "--f" | "--config") :: path :: rest ->
      ("--config=" ^ path) :: protect_command rest
  | "--f" :: rest -> "-f" :: protect_command rest
  | arg :: rest when String.starts_with ~prefix:"-f=" arg ->
      ("--config=" ^ String.sub arg 3 (String.length arg - 3))
      :: protect_command rest
  | arg :: rest when String.starts_with ~prefix:"--f=" arg ->
      ("--config=" ^ String.sub arg 4 (String.length arg - 4))
      :: protect_command rest
  | ("-h" | "--h" | "-help") :: rest -> "--help" :: protect_command rest
  | arg :: rest when arg <> "-" && String.starts_with ~prefix:"-" arg ->
      arg :: protect_command rest
  | args -> "--" :: args

let parse ?help ?err args =
  let argv = Array.of_list ("agent-wrapper" :: protect_command args) in
  Cmdliner.Cmd.eval_value ?help ?err ~catch:false ~argv command

let report message = Printf.eprintf "agent-wrapper: %s\n%!" message

let run_command (config_path, command, args) =
  try
    let environment = Environment.current () in
    let config_path =
      if config_path = "" then default_config_path environment
      else config_path
    in
    let config = Config.load config_path in
    Preconditions.check config.preconditions environment ;
    let environment = Environment.apply config.environment environment in
    let argv = Sandbox.build_argv config.sandbox environment command args in
    try Process.exec environment argv
    with System.Error message -> report message ; 125
  with System.Error message -> report message ; 1

let run args =
  match parse args with
  | Ok (`Ok invocation) -> run_command invocation
  | Ok (`Help | `Version) -> 0
  | Error _ -> 2
