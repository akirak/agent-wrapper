let has_path_prefix directory prefix =
  let directory = System.clean_path directory
  and prefix = System.clean_path prefix in
  directory = prefix
  || String.starts_with
       ~prefix:(if prefix = "/" then prefix else prefix ^ "/")
       directory

let real_working_directory () = Unix.realpath (Unix.getcwd ())

let check (config : Config.preconditions) environment =
  if config.check_environment then (
    if Environment.get environment "AGENTS_ALLOW_RUN" <> "1" then
      System.fail
        "refusing to run the agent: AGENTS_ALLOW_RUN is not set to \"1\".\n\
         If you really want to run an agent, set AGENTS_ALLOW_RUN=1 in the \
         environment." ;
    if config.allowed_working_directory_prefixes = [] then
      System.fail
        "refusing to run the agent: no allowed working directory prefixes \
         are configured in the config file" ;
    let cwd =
      System.protect "resolving the working directory" real_working_directory
    in
    if
      not
        (List.exists (has_path_prefix cwd)
           config.allowed_working_directory_prefixes )
    then
      System.fail
        "refusing to run the agent: %s is not under any of the allowed \
         working directory prefixes"
        cwd )
