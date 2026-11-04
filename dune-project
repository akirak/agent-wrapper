(lang dune 3.11)

(name agent-wrapper)

(generate_opam_files true)

(source
 (github akirak/agent-wrapper))

(authors "Akira Komamura")

(maintainers "Akira Komamura")

(license MIT)

(package
 (name agent-wrapper)
 (synopsis "Safety checks, secret loading, and sandboxing for coding agents")
 (description
  "A Unix command launcher with TOML-configured preconditions, file-backed environment variables, and optional Bubblewrap sandboxing.")
 (depends
  (ocaml (>= 4.13))
  (cmdliner (>= 1.1.0))
  (otoml (>= 1.0.5))))
