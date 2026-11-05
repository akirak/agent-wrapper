type preconditions =
  {check_environment: bool; allowed_working_directory_prefixes: string list}

type bubblewrap =
  {arguments: string list; extra_arguments: (string * string list) list}

type sandbox = {bubblewrap: bubblewrap option}

type environment_source = {file: string}

type t =
  { preconditions: preconditions
  ; sandbox: sandbox
  ; environment: (string * environment_source) list }

let empty_preconditions =
  {check_environment= false; allowed_working_directory_prefixes= []}

let empty_sandbox = {bubblewrap= None}

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
              { arguments= strings table "arguments"
              ; extra_arguments= extra_arguments table "extra_arguments" } )
            (find sandbox "bubblewrap") }
  ; environment=
      subtable root "environment"
      |> List.map (fun (key, value) ->
          (key, {file= string (table "environment source" value) "file"}) )
  }

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
