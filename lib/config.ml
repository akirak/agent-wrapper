type preconditions =
  {check_environment: bool; allowed_working_directory_prefixes: string list}

type bubblewrap =
  {arguments: string list; extra_arguments: (string * string list) list}

type sandbox = {bubblewrap: bubblewrap option}

type environment_source = {file: string}

type pass_through =
  {arguments: string list; extra_arguments: (string * string list) list}

type t =
  { preconditions: preconditions
  ; sandbox: sandbox
  ; environment: (string * environment_source) list
  ; pass_through: pass_through }

let empty_preconditions =
  {check_environment= false; allowed_working_directory_prefixes= []}

let empty_sandbox = {bubblewrap= None}

let default_pass_through_arguments = ["--help"; "--version"]

let empty_pass_through =
  {arguments= default_pass_through_arguments; extra_arguments= []}

let pass_through_arguments (config : pass_through) command =
  match
    List.assoc_opt (Filename.basename command) config.extra_arguments
  with
  | Some arguments -> arguments
  | None -> config.arguments

let should_pass_through (config : pass_through) command args =
  let arguments = pass_through_arguments config command in
  List.exists (fun arg -> List.mem arg arguments) args

let decode root =
  let open Otoml in
  let find table key = List.assoc_opt key table in
  let table name = function
    | TomlTable table | TomlInlineTable table -> table
    | _ -> System.fail "%s must be a table" name
  in
  let subtable parent name =
    match find parent name with None -> [] | Some value -> table name value
  in
  let boolean parent name =
    match find parent name with
    | None -> false
    | Some (TomlBoolean value) -> value
    | Some _ -> System.fail "%s must be a boolean" name
  in
  let strings parent name =
    match find parent name with
    | None -> []
    | Some (TomlArray values) ->
        List.map
          (function
            | TomlString value -> value
            | _ -> System.fail "%s must be an array of strings" name )
          values
    | Some _ -> System.fail "%s must be an array of strings" name
  in
  let string parent name =
    match find parent name with
    | None -> ""
    | Some (TomlString value) -> value
    | Some _ -> System.fail "%s must be a string" name
  in
  let extra_arguments parent name =
    match find parent name with
    | None -> []
    | Some (TomlTable entries | TomlInlineTable entries) ->
        List.map
          (fun (executable, values) ->
            (executable, strings [(executable, values)] executable) )
          entries
    | Some _ -> System.fail "%s must be a table of arrays of strings" name
  in
  let pass_through root =
    let arguments = ref default_pass_through_arguments in
    let extra_process = ref [] in
    let add_process executable arguments' =
      extra_process :=
        (executable, arguments')
        :: List.remove_assoc executable !extra_process
    in
    let add_entry name value =
      match value with
      | TomlArray _ ->
          let values = strings [(name, value)] name in
          if
            List.mem name
              ["arguments"; "default"; "default_arguments"; "defaults"; "*"]
          then arguments := values
          else add_process name values
      | _ -> System.fail "%s must be an array of strings" name
    in
    let add_map prefix entries =
      List.iter
        (fun (name, value) ->
          let path = prefix ^ "." ^ name in
          match value with
          | TomlArray _ -> add_process name (strings [(name, value)] path)
          | TomlTable entries | TomlInlineTable entries -> (
            match find entries "arguments" with
            | Some (TomlArray _) ->
                add_process name (strings entries (path ^ ".arguments"))
            | Some _ ->
                System.fail "%s.arguments must be an array of strings" path
            | None ->
                System.fail
                  "%s must be an array of strings or contain an arguments \
                   array"
                  path )
          | _ -> System.fail "%s must be an array of strings" path )
        entries
    in
    let rec consume prefix entries =
      List.iter
        (fun (name, value) ->
          let path = prefix ^ "." ^ name in
          match value with
          | TomlArray _ -> add_entry name value
          | TomlTable entries | TomlInlineTable entries -> (
            match name with
            | "arguments" | "default_arguments" | "defaults"
             |"extra_arguments" | "by_process" | "processes" | "commands"
             |"overrides" | "arguments_by_process"
             |"arguments_by_executable" ->
                add_map path entries
            | "default" | "*" -> consume path entries
            | _ -> (
              match find entries "arguments" with
              | Some (TomlArray _) ->
                  add_process name (strings entries "arguments")
              | Some _ ->
                  System.fail "%s.arguments must be an array of strings" path
              | None -> consume path entries ) )
          | _ -> System.fail "%s must be an array of strings or a table" path )
        entries
    in
    let section value =
      match value with
      | TomlArray _ ->
          arguments := strings [("pass_through", value)] "pass_through"
      | TomlTable _ | TomlInlineTable _ ->
          consume "pass_through" (table "pass_through" value)
      | _ ->
          System.fail "pass_through must be a table or an array of strings"
    in
    Option.iter section (find root "pass_through") ;
    Option.iter section (find root "pass_through_arguments") ;
    ( match find root "preconditions" with
    | Some (TomlTable entries | TomlInlineTable entries) ->
        Option.iter section (find entries "pass_through") ;
        Option.iter section (find entries "pass_through_arguments")
    | Some _ -> ()
    | None -> () ) ;
    {arguments= !arguments; extra_arguments= List.rev !extra_process}
  in
  let root = table "config" root in
  let preconditions = subtable root "preconditions" in
  let sandbox = subtable root "sandbox" in
  { preconditions=
      { check_environment= boolean preconditions "check_environment"
      ; allowed_working_directory_prefixes=
          strings preconditions "allowed_working_directory_prefixes" }
  ; sandbox=
      { bubblewrap=
          Option.map
            (fun value ->
              let table = table "sandbox.bubblewrap" value in
              ( { arguments= strings table "arguments"
                ; extra_arguments= extra_arguments table "extra_arguments" }
                : bubblewrap ) )
            (find sandbox "bubblewrap") }
  ; environment=
      subtable root "environment"
      |> List.map (fun (key, value) ->
          (key, {file= string (table "environment source" value) "file"}) )
  ; pass_through= pass_through root }

let load path =
  let data =
    System.protect "reading config file" (fun () -> System.read_file path)
  in
  try
    match Otoml.Parser.from_string_result data with
    | Ok root -> decode root
    | Error message -> raise (System.Error message)
  with System.Error message ->
    System.fail "parsing config file %s: %s" path message
