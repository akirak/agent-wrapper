open Agent_wrapper

let check condition message = if not condition then failwith message

let equal expected actual =
  if expected <> actual then failwith "values differ"

let contains text part =
  let rec loop index =
    index + String.length part <= String.length text
    && (String.sub text index (String.length part) = part || loop (index + 1))
  in
  loop 0

let expect_error ?(message = "") f =
  match f () with
  | _ -> failwith "expected an error"
  | exception System.Error actual ->
      check (contains actual message) ("unexpected error: " ^ actual)

let write path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel contents)

let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then (
    Array.iter
      (fun name -> remove (Filename.concat path name))
      (Sys.readdir path) ;
    Unix.rmdir path )
  else Unix.unlink path

let with_temp f =
  let directory = Filename.temp_file "agent-wrapper-test-" "" in
  Unix.unlink directory ;
  Unix.mkdir directory 0o700 ;
  Fun.protect ~finally:(fun () -> remove directory) (fun () -> f directory)

let with_cwd directory f =
  let previous = Unix.getcwd () in
  Fun.protect
    ~finally:(fun () -> Unix.chdir previous)
    (fun () -> Unix.chdir directory ; f ())

let environment entries =
  List.map (fun (name, value) -> name ^ "=" ^ value) entries
  |> Array.of_list |> Environment.of_array

let source file : Config.environment_source = {file}

let sandbox ?(extra_arguments = []) arguments : Config.sandbox =
  {bubblewrap= Some {arguments; extra_arguments}}

let sh =
  System.look_path
    ~path:(Environment.get (Environment.current ()) "PATH")
    "sh"

let test_path_prefix () =
  List.iter
    (fun (directory, prefix, expected) ->
      check
        (Preconditions.has_path_prefix directory prefix = expected)
        (Printf.sprintf "has_path_prefix %S %S" directory prefix) )
    [ ("/git/work", "/git", true)
    ; ("/git", "/git", true)
    ; ("/git/", "/git", true)
    ; ("/github", "/git", false)
    ; ("/git/work", "/git/work/project", false)
    ; ("/git/work", "/git/w", false)
    ; ("/tmp/x-y", "/tmp/x", false)
    ; ("/tmp/x/y", "/tmp/x/", true)
    ; ("/git/work", "/", true)
    ; ("/", "/", true)
    ; ("/", "/git", false)
    ; ("/git//work/../project/.", "/git/project/", true)
    ; ("/git/../github", "/git", false)
    ; ("/work", "$HOME", false)
    ; ("a/b", "a/./b", true)
    ; ("../a", "..", true) ]

let test_load_config () =
  with_temp (fun dir ->
      let path = Filename.concat dir "config.toml" in
      write path
        {|[preconditions]
check_environment = true
allowed_working_directory_prefixes = [ "/git", "$HOME" ]
[sandbox.bubblewrap]
arguments = ["--bind", "$HOME", "$HOME", "--unshare-all"]
[sandbox.bubblewrap.extra_arguments]
pi = ["--bind-try", "$HOME/.pi", "$HOME/.pi"]
claude = []
"with space" = ["flag"]
[environment]
CMD_API_KEY = { file = "/run/ageism/commandcode-api-key" }
"with space" = { file = 'literal\path' }
"quote\"name" = { file = "quoted" }
[environment.NESTED]
file = "nested"
|} ;
      let config = Config.load path in
      check config.preconditions.check_environment
        "safety checks not decoded" ;
      equal ["/git"; "$HOME"]
        config.preconditions.allowed_working_directory_prefixes ;
      equal
        (sandbox
           ~extra_arguments:
             [ ("pi", ["--bind-try"; "$HOME/.pi"; "$HOME/.pi"])
             ; ("claude", [])
             ; ("with space", ["flag"]) ]
           ["--bind"; "$HOME"; "$HOME"; "--unshare-all"] )
        config.sandbox ;
      equal "/run/ageism/commandcode-api-key"
        (List.assoc "CMD_API_KEY" config.environment).file ;
      equal "literal\\path" (List.assoc "with space" config.environment).file ;
      equal "quoted" (List.assoc "quote\"name" config.environment).file ;
      equal "nested" (List.assoc "NESTED" config.environment).file ;
      write path "" ;
      let config = Config.load path in
      equal Config.empty_preconditions config.preconditions ;
      equal Config.empty_sandbox config.sandbox ;
      equal [] config.environment ;
      write path "[preconditions]\ncheck_environment = false\n" ;
      equal None (Config.load path).sandbox.bubblewrap ;
      write path "[sandbox.bubblewrap]\n" ;
      equal (sandbox []) (Config.load path).sandbox ;
      write path "unknown = 'ignored'\n[sandbox]\n" ;
      equal None (Config.load path).sandbox.bubblewrap ;
      List.iter
        (fun content ->
          write path content ;
          expect_error ~message:"parsing config file" (fun () ->
              Config.load path ) )
        [ "[invalid"
        ; "x = 1\nx = 2"
        ; "[preconditions]\ncheck_environment = 'true'"
        ; "[preconditions]\nallowed_working_directory_prefixes = [1]"
        ; "[preconditions]\nallowed_working_directory_prefixes = ['/git', 1]"
        ; "preconditions = false"
        ; "sandbox = false"
        ; "[sandbox]\nbubblewrap = false"
        ; "[sandbox.bubblewrap]\narguments = 'bad'"
        ; "[sandbox.bubblewrap]\nextra_arguments = 'bad'"
        ; "[sandbox.bubblewrap]\nextra_arguments = { pi = 'bad' }"
        ; "[sandbox.bubblewrap]\nextra_arguments = { pi = [1] }"
        ; "environment = []"
        ; "[environment]\nTOKEN = 'bad'"
        ; "[environment]\nTOKEN = { file = 1 }" ] ;
      expect_error ~message:"reading config file" (fun () ->
          Config.load (Filename.concat dir "missing") ) )

let test_preconditions () =
  with_temp (fun dir ->
      let dir = Unix.realpath dir in
      let sub = Filename.concat dir "sub" in
      Unix.mkdir sub 0o700 ;
      with_cwd sub (fun () ->
          let config : Config.preconditions =
            { check_environment= true
            ; allowed_working_directory_prefixes= [dir] }
          in
          List.iter
            (fun flag ->
              expect_error ~message:"AGENTS_ALLOW_RUN" (fun () ->
                  Preconditions.check config
                    (environment [("AGENTS_ALLOW_RUN", flag)]) ) )
            [""; "0"; "true"; "01"] ;
          let allowed = environment [("AGENTS_ALLOW_RUN", "1")] in
          expect_error ~message:"no allowed working directory prefixes"
            (fun () ->
              Preconditions.check
                {config with allowed_working_directory_prefixes= []}
                allowed ) ;
          expect_error ~message:"not under any" (fun () ->
              Preconditions.check
                { config with
                  allowed_working_directory_prefixes=
                    [Filename.concat dir "other"] }
                allowed ) ;
          Preconditions.check
            {config with allowed_working_directory_prefixes= ["/usr"; dir]}
            allowed ;
          Preconditions.check
            {config with allowed_working_directory_prefixes= ["/"]}
            allowed ;
          Preconditions.check Config.empty_preconditions (environment []) ) ;
      let link = Filename.concat dir "link" in
      Unix.symlink sub link ;
      with_cwd link (fun () ->
          equal sub (Preconditions.real_working_directory ()) ;
          expect_error ~message:"not under any" (fun () ->
              Preconditions.check
                { check_environment= true
                ; allowed_working_directory_prefixes= [link] }
                (environment [("AGENTS_ALLOW_RUN", "1")]) ) ) )

let test_environment () =
  with_temp (fun dir ->
      let token = Filename.concat dir "token" in
      let missing = Filename.concat dir "missing" in
      write token "  \011\xc2\xa0\xe3\x80\x80secret-token-123\xe2\x80\xaf\n" ;
      let original =
        environment [("AW_TOKEN", "inherited"); ("AW_ABSENT", "inherited")]
      in
      let result =
        Environment.apply
          [("AW_TOKEN", source token); ("AW_ABSENT", source missing)]
          original
      in
      equal "secret-token-123" (Environment.get result "AW_TOKEN") ;
      check
        (not (Environment.Variables.mem "AW_ABSENT" result))
        "missing file did not unset variable" ;
      equal "inherited" (Environment.get original "AW_ABSENT") ;
      List.iter
        (fun name ->
          expect_error ~message:"invalid environment variable name"
            (fun () -> Environment.apply [(name, source token)] original ) )
        [""; "BAD=NAME"; "BAD\000NAME"] ;
      expect_error ~message:"reading the value" (fun () ->
          Environment.apply [("AW_ERROR", source dir)] original ) ;
      expect_error ~message:"reading the value" (fun () ->
          Environment.apply
            [("AW_ERROR", source (Filename.concat token "child"))]
            original ) ;
      write token "" ;
      let result = Environment.apply [("AW_TOKEN", source token)] original in
      check
        (Environment.Variables.mem "AW_TOKEN" result)
        "empty file should set an empty value" ;
      equal "" (Environment.get result "AW_TOKEN") ;
      write token "secret\000value" ;
      expect_error ~message:"setting the environment variable" (fun () ->
          Environment.apply [("AW_TOKEN", source token)] original ) ;
      Unix.symlink missing (Filename.concat dir "dangling") ;
      let result =
        Environment.apply
          [("AW_TOKEN", source (Filename.concat dir "dangling"))]
          original
      in
      check
        (not (Environment.Variables.mem "AW_TOKEN" result))
        "dangling symlink should unset" ;
      check
        (Environment.Variables.equal String.equal original
           (Environment.of_array (Environment.to_array original)) )
        "environment round-trip changed values" ;
      List.iter
        (fun value -> equal "" (Environment.trim_space value))
        Environment.whitespace )

let test_expansion () =
  let env =
    environment [("HOME", "/home/user"); ("X", "a b"); ("1", "one")]
  in
  List.iter
    (fun (text, expected) -> equal expected (Environment.expand env text))
    [ ("$HOME", "/home/user")
    ; ("$HOME/.config/direnv", "/home/user/.config/direnv")
    ; ("--path=${HOME}/$X", "--path=/home/user/a b")
    ; ("${HOME}/x", "/home/user/x")
    ; ("$MISSING", "")
    ; ("$HOME/$X", "/home/user/a b")
    ; ("$X", "a b")
    ; ("$", "$")
    ; ("$$", "")
    ; ("${}", "")
    ; ("${HOME", "HOME")
    ; ("$%", "$%")
    ; ("$1x", "onex")
    ; ("${HOME:-fallback}", "")
    ; ("$(echo bad)", "$(echo bad)") ]

let test_sandbox () =
  let env = environment [] in
  equal
    ["claude"; "--foo"; "bar"]
    (Sandbox.build_argv Config.empty_sandbox env "claude" ["--foo"; "bar"]) ;
  with_temp (fun dir ->
      let bwrap = Filename.concat dir "bwrap" in
      write bwrap ("#!" ^ sh ^ "\nexit 0\n") ;
      Unix.chmod bwrap 0o700 ;
      let env =
        environment
          [("PATH", dir); ("HOME", "/home/user"); ("AW_HOME", "/home/a b")]
      in
      let config =
        sandbox
          [ "--bind"
          ; "$AW_HOME"
          ; "$AW_HOME"
          ; "--unshare-all"
          ; "$HOME/.config/direnv"
          ; "--chdir=${AW_HOME}/$HOME"
          ; "no$expansion"
          ; "${AW_HOME}/x"
          ; "$MISSING"
          ; "$(echo bad)" ]
      in
      if Platform.system = "linux" then (
        equal
          [ bwrap
          ; "--bind"
          ; "/home/a b"
          ; "/home/a b"
          ; "--unshare-all"
          ; "/home/user/.config/direnv"
          ; "--chdir=/home/a b//home/user"
          ; "no"
          ; "/home/a b/x"
          ; ""
          ; "$(echo bad)"
          ; "claude"
          ; "--verbose" ]
          (Sandbox.build_argv config env "claude" ["--verbose"]) ;
        let extra =
          sandbox
            ~extra_arguments:
              [("claude", ["--ro-bind"; "$HOME/.claude"]); ("pi", ["--pi"])]
            ["--unshare-all"]
        in
        equal
          [ bwrap
          ; "--unshare-all"
          ; "--ro-bind"
          ; "/home/user/.claude"
          ; "claude"
          ; "--verbose" ]
          (Sandbox.build_argv extra env "claude" ["--verbose"]) ;
        equal
          [bwrap; "--unshare-all"; "--pi"; "/usr/bin/pi"; "--flag"]
          (Sandbox.build_argv extra env "/usr/bin/pi" ["--flag"]) ;
        equal
          [bwrap; "--unshare-all"; "other"; "--flag"]
          (Sandbox.build_argv extra env "other" ["--flag"]) ;
        expect_error ~message:"bwrap was configured but is not available"
          (fun () ->
            Sandbox.build_argv config
              (environment [("PATH", "")])
              "claude" [] ) )
      else
        equal ["claude"; "--verbose"]
          (Sandbox.build_argv config env "claude" ["--verbose"]) ;
      equal bwrap (System.look_path ~path:dir "bwrap") ;
      with_cwd dir (fun () ->
          equal "./bwrap" (System.look_path ~path:"" "./bwrap") ;
          expect_error ~message:"relative to current directory" (fun () ->
              System.look_path ~path:"." "bwrap" ) ) ;
      Unix.chmod bwrap 0o600 ;
      expect_error (fun () -> System.look_path ~path:dir "bwrap") ;
      expect_error (fun () -> System.look_path ~path:dir dir) )

let test_default_config_path () =
  equal "/xdg/agent-wrapper/config.toml"
    (Cli.default_config_path
       (environment [("XDG_CONFIG_HOME", "/xdg"); ("HOME", "/home/user")]) ) ;
  equal "/home/user/.config/agent-wrapper/config.toml"
    (Cli.default_config_path
       (environment [("XDG_CONFIG_HOME", ""); ("HOME", "/home/user")]) ) ;
  expect_error ~message:"neither XDG_CONFIG_HOME nor HOME" (fun () ->
      Cli.default_config_path (environment []) )

let test_cli () =
  let quiet = Format.formatter_of_buffer (Buffer.create 128) in
  let parse args = Cli.parse ~help:quiet ~err:quiet args in
  let parsed args =
    match parse args with
    | Ok (`Ok invocation) -> invocation
    | _ -> failwith "expected a parsed command line"
  in
  List.iter
    (fun args ->
      equal
        ("config", "agent", ["-f"; "agent-option"])
        (parsed (args @ ["agent"; "-f"; "agent-option"])) )
    [ ["-f"; "config"]
    ; ["--f"; "config"]
    ; ["-f=config"]
    ; ["--f=config"]
    ; ["--config"; "config"]
    ; ["--config=config"]
    ; ["-fconfig"]
    ; ["-f"; "earlier"; "--config=config"] ] ;
  equal ("", "agent", []) (parsed ["agent"]) ;
  equal ("", "-agent", ["--help"]) (parsed ["--"; "-agent"; "--help"]) ;
  equal ("", "-", []) (parsed ["-"]) ;
  equal ("-config", "agent", []) (parsed ["-f"; "-config"; "agent"]) ;
  equal ("", "agent", []) (parsed ["-f="; "agent"]) ;
  let forwarded = ["--help"; "--unknown"; "--"; "-f"; ""; "--config=x"] in
  equal ("", "agent", forwarded) (parsed ("agent" :: forwarded)) ;
  equal (Ok `Help) (parse ["--help=plain"]) ;
  List.iter
    (fun args ->
      match parse args with
      | Error (`Parse | `Term) -> ()
      | _ -> failwith "expected a command-line error" )
    [ []
    ; ["--"]
    ; ["-f"]
    ; ["--f"]
    ; ["--config"]
    ; ["--unknown"]
    ; ["-f"; "config"]
    ; ["--unknown"; "agent"] ] ;
  equal 2 (Cli.run []) ;
  equal 2 (Cli.run ["-f"]) ;
  equal 2 (Cli.run ["--unknown"]) ;
  with_temp (fun dir ->
      let config = Filename.concat dir "config.toml" in
      write config "" ;
      equal 2 (Cli.run ["-f"; config]) ;
      equal 1 (Cli.run ["-f"; Filename.concat dir "missing"; "true"]) ;
      equal 125 (Cli.run ["-f"; config; "definitely-not-a-command-xyz"]) )

type execution =
  {output: string; error: string; status: Unix.process_status; pid: int}

let execute ~dir ~env program args =
  let output_path = Filename.concat dir "stdout"
  and error_path = Filename.concat dir "stderr" in
  let output =
    Unix.openfile output_path
      [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC]
      0o600
  in
  let error =
    Unix.openfile error_path
      [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC]
      0o600
  in
  let pid =
    Fun.protect
      ~finally:(fun () -> Unix.close output ; Unix.close error)
      (fun () ->
        Unix.create_process_env program
          (Array.of_list (program :: args))
          (Environment.to_array env)
          Unix.stdin output error )
  in
  let rec wait () =
    try snd (Unix.waitpid [] pid)
    with Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
  in
  let status = wait () in
  { output= System.read_file output_path
  ; error= System.read_file error_path
  ; status
  ; pid }

let assert_execution ?(output = "") status result =
  if result.status <> status || result.output <> output then
    failwith
      (Printf.sprintf "unexpected execution: stdout=%S stderr=%S"
         result.output result.error )

let test_end_to_end binary () =
  with_temp (fun dir ->
      let dir = Unix.realpath dir in
      with_cwd dir (fun () ->
          let token = Filename.concat dir "token" in
          let config_path = Filename.concat dir "config.toml" in
          write token "e2e-token\n" ;
          let config =
            Printf.sprintf
              "[preconditions]\n\
               check_environment = true\n\
               allowed_working_directory_prefixes = [%S]\n\
               [environment]\n\
               AW_E2E_TOKEN = { file = %S }\n\
               AW_E2E_ABSENT = { file = %S }\n"
              dir token
              (Filename.concat dir "missing")
          in
          write config_path config ;
          let env =
            Environment.current ()
            |> Environment.Variables.add "AGENTS_ALLOW_RUN" "1"
            |> Environment.Variables.add "AW_E2E_ABSENT" "inherited"
          in
          let run ?(env = env) args = execute ~dir ~env binary args in
          let wrapped args = run (["-f"; config_path] @ args) in
          List.iter
            (fun option ->
              let help = run ~env:(environment []) [option] in
              equal (Unix.WEXITED 0) help.status ;
              equal "" help.error ;
              check
                ( contains help.output "--config"
                && contains help.output "COMMAND"
                && contains help.output "$XDG_CONFIG_HOME" )
                "missing generated help" )
            ["-h"; "--h"; "-help"; "--help"; "--help=plain"] ;
          let invalid_args = run ["--unknown"] in
          assert_execution (Unix.WEXITED 2) invalid_args ;
          check (contains invalid_args.error "unknown") "missing CLI error" ;
          let refused =
            run
              ~env:(Environment.Variables.remove "AGENTS_ALLOW_RUN" env)
              ["-f"; config_path; sh; "-c"; "echo should-not-run"]
          in
          assert_execution (Unix.WEXITED 1) refused ;
          check
            (contains refused.error "AGENTS_ALLOW_RUN")
            "missing precondition error" ;
          assert_execution ~output:"e2e-token unset" (Unix.WEXITED 0)
            (wrapped
               [ sh
               ; "-c"
               ; "printf '%s %s' \"$AW_E2E_TOKEN\" \
                  \"${AW_E2E_ABSENT-unset}\"" ] ) ;
          assert_execution (Unix.WEXITED 42) (wrapped [sh; "-c"; "exit 42"]) ;
          assert_execution (Unix.WSIGNALED Sys.sigterm)
            (wrapped [sh; "-c"; "kill -TERM $$"]) ;
          let pid = wrapped [sh; "-c"; "printf '%s' \"$$\""] in
          assert_execution ~output:(string_of_int pid.pid) (Unix.WEXITED 0)
            pid ;
          assert_execution ~output:"a b|--help|$literal" (Unix.WEXITED 0)
            (wrapped
               [ sh
               ; "-c"
               ; "printf '%s|%s|%s' \"$1\" \"$2\" \"$3\""
               ; "agent"
               ; "a b"
               ; "--help"
               ; "$literal" ] ) ;
          let forwarded =
            [ "-f"
            ; "other"
            ; "--config=other"
            ; "--unknown"
            ; "--help=plain"
            ; "--"
            ; ""
            ; "-" ]
          in
          assert_execution
            ~output:
              (String.concat ""
                 (List.map (Printf.sprintf "<%s>\n") forwarded) )
            (Unix.WEXITED 0)
            (wrapped
               ([sh; "-c"; "printf '<%s>\\n' \"$@\""; "agent"] @ forwarded) ) ;
          assert_execution (Unix.WEXITED 125)
            (wrapped ["definitely-not-a-command-xyz"]) ;
          let invalid = Filename.concat dir "not-executable" in
          write invalid "not an executable format\n" ;
          Unix.chmod invalid 0o700 ;
          assert_execution (Unix.WEXITED 125) (wrapped [invalid]) ;
          write config_path "[invalid" ;
          assert_execution (Unix.WEXITED 1)
            (wrapped [sh; "-c"; "echo should-not-run"]) ;
          write config_path
            ( config ^ "[environment.AGENTS_ALLOW_RUN]\nfile = "
            ^ Printf.sprintf "%S\n" token ) ;
          assert_execution (Unix.WEXITED 1)
            (run
               ~env:(Environment.Variables.remove "AGENTS_ALLOW_RUN" env)
               ["-f"; config_path; sh; "-c"; "echo should-not-run"] ) ;
          write config_path config ;
          let xdg = Filename.concat dir "xdg" in
          Unix.mkdir xdg 0o700 ;
          let config_dir = Filename.concat xdg "agent-wrapper" in
          Unix.mkdir config_dir 0o700 ;
          write (Filename.concat config_dir "config.toml") config ;
          assert_execution ~output:"default-config" (Unix.WEXITED 0)
            (run
               ~env:(Environment.Variables.add "XDG_CONFIG_HOME" xdg env)
               [sh; "-c"; "printf default-config"] ) ;
          if Platform.system = "linux" then (
            (* A mock makes argv/exec coverage independent of kernel
               namespace permissions and the presence of the real bwrap
               binary. *)
            let bwrap = Filename.concat dir "bwrap" in
            write bwrap ("#!" ^ sh ^ "\nprintf '<%s>\\n' \"$@\"\n") ;
            Unix.chmod bwrap 0o700 ;
            let path_file = Filename.concat dir "path" in
            write path_file (dir ^ "\n") ;
            write config_path
              ( config
              ^ Printf.sprintf
                  "PATH = { file = %S }\n\
                   [sandbox.bubblewrap]\n\
                   arguments = [\"--bind\", \"$AW_E2E_TOKEN\", \
                   \"${AW_E2E_TOKEN}/x\", \"prefix-${AW_E2E_TOKEN}/x\", \
                   \"no$AW_E2E_ABSENT\", \"$AW_E2E_ABSENT\"]\n"
                  path_file ) ;
            assert_execution
              ~output:
                "<--bind>\n\
                 <e2e-token>\n\
                 <e2e-token/x>\n\
                 <prefix-e2e-token/x>\n\
                 <no>\n\
                 <>\n\
                 <agent>\n\
                 <--verbose>\n"
              (Unix.WEXITED 0)
              (wrapped ["agent"; "--verbose"]) ;
            write config_path (config ^ "[sandbox.bubblewrap]\n") ;
            assert_execution (Unix.WEXITED 1)
              (run
                 ~env:(Environment.Variables.add "PATH" "" env)
                 ["-f"; config_path; sh] ) ;
            let real_bwrap =
              try
                Some
                  (System.look_path
                     ~path:(Environment.get env "PATH")
                     "bwrap" )
              with System.Error _ -> None
            in
            match real_bwrap with
            | None ->
                print_endline "  SKIP real Bubblewrap: bwrap not installed"
            | Some bwrap ->
                let arguments =
                  [ "--unshare-all"
                  ; "--proc"
                  ; "/proc"
                  ; "--dev"
                  ; "/dev"
                  ; "--ro-bind"
                  ; "/"
                  ; "/" ]
                in
                let probe =
                  execute ~dir ~env bwrap (arguments @ [sh; "-c"; "exit 0"])
                in
                if probe.status <> Unix.WEXITED 0 then
                  Printf.printf "  SKIP real Bubblewrap: %s\n"
                    (String.trim probe.error)
                else (
                  write config_path
                    ( config ^ "[sandbox.bubblewrap]\narguments = ["
                    ^ String.concat ", "
                        (List.map (Printf.sprintf "%S") arguments)
                    ^ "]\n" ) ;
                  assert_execution ~output:"e2e-token" (Unix.WEXITED 0)
                    (wrapped [sh; "-c"; "printf '%s' \"$AW_E2E_TOKEN\""]) ) ) ) )

let () =
  Printexc.record_backtrace true ;
  let binary = Unix.realpath Sys.argv.(1) in
  let tests =
    [ ("component-wise path prefixes", test_path_prefix)
    ; ("TOML configuration and validation", test_load_config)
    ; ("safety preconditions and real paths", test_preconditions)
    ; ("file-backed environment", test_environment)
    ; ("environment expansion", test_expansion)
    ; ("sandbox argument construction and executable lookup", test_sandbox)
    ; ("default configuration path", test_default_config_path)
    ; ("command-line parsing and failures", test_cli)
    ; ("end-to-end execution", test_end_to_end binary) ]
  in
  let failures = ref 0 in
  List.iter
    (fun (name, test) ->
      try
        test () ;
        Printf.printf "PASS %s\n%!" name
      with exn ->
        incr failures ;
        Printf.eprintf "FAIL %s: %s\n%s%!" name (Printexc.to_string exn)
          (Printexc.get_backtrace ()) )
    tests ;
  if !failures <> 0 then exit 1
