module Variables = Map.Make (String)

type t = string Variables.t

let of_array entries =
  Array.fold_left
    (fun variables entry ->
      match String.index_opt entry '=' with
      | None -> variables
      | Some index ->
          Variables.add
            (String.sub entry 0 index)
            (String.sub entry (index + 1) (String.length entry - index - 1))
            variables )
    Variables.empty entries

let current () = of_array (Unix.environment ())

let get variables name =
  Option.value ~default:"" (Variables.find_opt name variables)

let to_array variables =
  Variables.bindings variables
  |> List.map (fun (name, value) -> name ^ "=" ^ value)
  |> Array.of_list

let check_name name =
  if name = "" then System.fail "the name is empty" ;
  if String.contains name '=' || String.contains name '\000' then
    System.fail "the name contains a forbidden character"

(* Unicode White_Space, matching Go's strings.TrimSpace on UTF-8 input. *)
let whitespace =
  [ " "
  ; "\t"
  ; "\n"
  ; "\011"
  ; "\012"
  ; "\r"
  ; "\xc2\x85"
  ; "\xc2\xa0"
  ; "\xe1\x9a\x80"
  ; "\xe2\x80\x80"
  ; "\xe2\x80\x81"
  ; "\xe2\x80\x82"
  ; "\xe2\x80\x83"
  ; "\xe2\x80\x84"
  ; "\xe2\x80\x85"
  ; "\xe2\x80\x86"
  ; "\xe2\x80\x87"
  ; "\xe2\x80\x88"
  ; "\xe2\x80\x89"
  ; "\xe2\x80\x8a"
  ; "\xe2\x80\xa8"
  ; "\xe2\x80\xa9"
  ; "\xe2\x80\xaf"
  ; "\xe2\x81\x9f"
  ; "\xe3\x80\x80" ]

let trim_space value =
  let matches index space =
    index >= 0
    && index + String.length space <= String.length value
    && String.sub value index (String.length space) = space
  in
  let rec left index =
    match List.find_opt (matches index) whitespace with
    | Some space -> left (index + String.length space)
    | None -> index
  in
  let first = left 0 in
  let rec right index =
    match
      List.find_opt
        (fun space ->
          index - String.length space >= first
          && matches (index - String.length space) space )
        whitespace
    with
    | Some space -> right (index - String.length space)
    | None -> index
  in
  String.sub value first (right (String.length value) - first)

(* Keep an explicit environment so missing files really remove inherited
   variables, including on OCaml versions without Unix.unsetenv. This same
   environment is used for expansion, PATH lookup, and execve. *)
let apply sources variables =
  List.fold_left
    (fun variables (name, source) ->
      ( try check_name name
        with System.Error message ->
          System.fail
            "invalid environment variable name %S in the config file: %s"
            name message ) ;
      let value =
        try Some (System.read_file source.Config.file) with
        | Unix.Unix_error (Unix.ENOENT, _, _) -> None
        | (Unix.Unix_error _ | Sys_error _ | Invalid_argument _) as exn ->
            System.fail
              "reading the value of the environment variable %s from %s: %s"
              name source.file
              (System.error_message exn)
      in
      match value with
      | None -> Variables.remove name variables
      | Some value ->
          let value = trim_space value in
          if String.contains value '\000' then
            System.fail
              "setting the environment variable %s: value contains NUL" name ;
          Variables.add name value variables )
    variables sources

(* Go-style os.ExpandEnv: no shell evaluation, splitting, or default
   values. *)
let expand variables text =
  let length = String.length text
  and buffer = Buffer.create (String.length text) in
  let alphanumeric = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
    | _ -> false
  in
  let rec name_end index =
    if index < length && alphanumeric text.[index] then name_end (index + 1)
    else index
  in
  let rec loop index =
    if index >= length then Buffer.contents buffer
    else if text.[index] <> '$' || index + 1 = length then (
      Buffer.add_char buffer text.[index] ;
      loop (index + 1) )
    else
      let start = index + 1 in
      match text.[start] with
      | '{' -> (
        match String.index_from_opt text (start + 1) '}' with
        | None -> loop (start + 1)
        | Some ending ->
            Buffer.add_string buffer
              (get variables
                 (String.sub text (start + 1) (ending - start - 1)) ) ;
            loop (ending + 1) )
      | ('*' | '#' | '$' | '@' | '!' | '?' | '-' | '0' .. '9') as special ->
          Buffer.add_string buffer (get variables (String.make 1 special)) ;
          loop (start + 1)
      | _ ->
          let ending = name_end start in
          if ending = start then Buffer.add_char buffer '$'
          else
            Buffer.add_string buffer
              (get variables (String.sub text start (ending - start))) ;
          loop ending
  in
  loop 0
