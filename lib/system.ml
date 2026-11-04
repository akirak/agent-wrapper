exception Error of string

let fail format =
  Printf.ksprintf (fun message -> raise (Error message)) format

let error_message = function
  | Unix.Unix_error (error, call, path) ->
      Printf.sprintf "%s %s: %s" call path (Unix.error_message error)
  | Sys_error message | Invalid_argument message -> message
  | exn -> Printexc.to_string exn

let protect context f =
  try f ()
  with (Unix.Unix_error _ | Sys_error _ | Invalid_argument _) as exn ->
    fail "%s: %s" context (error_message exn)

let read_file path =
  let fd = Unix.openfile path [Unix.O_RDONLY; Unix.O_CLOEXEC] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      let buffer = Buffer.create 256 and chunk = Bytes.create 4096 in
      let rec read () =
        match Unix.read fd chunk 0 (Bytes.length chunk) with
        | 0 -> Buffer.contents buffer
        | count ->
            Buffer.add_subbytes buffer chunk 0 count ;
            read ()
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> read ()
      in
      read () )

(* Lexical cleaning, like filepath.Clean: do not resolve configured
   symlinks. *)
let clean_path path =
  let absolute = not (Filename.is_relative path) in
  let parts =
    List.fold_left
      (fun parts -> function
        | "" | "." -> parts
        | ".." -> (
          match parts with
          | part :: rest when part <> ".." -> rest
          | _ -> if absolute then parts else ".." :: parts )
        | part -> part :: parts )
      []
      (String.split_on_char '/' path)
  in
  match (absolute, List.rev parts) with
  | true, parts -> "/" ^ String.concat "/" parts
  | false, [] -> "."
  | false, parts -> String.concat "/" parts

let look_path ~path command =
  let executable file =
    try
      (Unix.stat file).Unix.st_kind <> Unix.S_DIR
      &&
      ( Unix.access file [Unix.X_OK] ;
        true )
    with Unix.Unix_error _ -> false
  in
  if String.contains command '/' then
    if executable command then command
    else fail "%s: not an executable file" command
  else
    let rec search = function
      | [] -> fail "%s: executable file not found in PATH" command
      | dir :: rest ->
          let file =
            Filename.concat (if dir = "" then "." else dir) command
          in
          if not (executable file) then search rest
          else if Filename.is_relative file then
            fail
              "%s: cannot run executable found relative to current directory"
              command
          else file
    in
    search (if path = "" then [] else String.split_on_char ':' path)
