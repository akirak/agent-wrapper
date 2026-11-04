let () =
  Sys.argv |> Array.to_list |> List.tl |> Agent_wrapper.Cli.run |> exit
