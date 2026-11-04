let exec environment = function
  | [] -> System.fail "cannot execute an empty argument vector"
  | command :: _ as argv ->
      let path =
        System.look_path ~path:(Environment.get environment "PATH") command
      in
      System.protect ("exec " ^ command) (fun () ->
          (* No subprocess or shell fallback: preserve PID, terminal,
             signals, and the agent's exit status just as the original Unix
             launcher. *)
          Unix.execve path (Array.of_list argv)
            (Environment.to_array environment) )
