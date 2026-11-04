let build_argv (config : Config.sandbox) environment command args =
  match config.bubblewrap with
  | None -> command :: args
  | Some _ when Platform.system <> "linux" ->
      let system =
        if Platform.system = "macosx" then "darwin" else Platform.system
      in
      Printf.eprintf
        "agent-wrapper: warning: the bubblewrap sandbox is not supported on \
         %s; running %s without a sandbox\n\
         %!"
        system command ;
      command :: args
  | Some bubblewrap ->
      let bwrap =
        try
          System.look_path ~path:(Environment.get environment "PATH") "bwrap"
        with System.Error message ->
          System.fail "bwrap was configured but is not available: %s" message
      in
      let arguments =
        List.map
          (fun arg ->
            if String.starts_with ~prefix:"$" arg then
              Environment.expand environment arg
            else arg )
          bubblewrap.arguments
      in
      bwrap :: (arguments @ (command :: args))
