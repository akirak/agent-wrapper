# agent-wrapper

`agent-wrapper` is a lightweight command-line wrapper for coding agents, configured via a TOML file.

It acts as a pre-flight launcher before executing an agent command:

1. **Precondition checks** — Prevents accidentally starting an agent outside designated directories or without explicit opt-in.
2. **Secret loading** — Populates environment variables (such as API keys) from files on disk so secrets do not need to be exported in shell profiles.
3. **Bubblewrap sandboxing (Linux)** — Optionally runs the agent inside a [Bubblewrap (`bwrap`)](https://github.com/containers/bubblewrap) container with user-defined arguments.

> [!WARNING]
> This is an internal/personal utility intended as a lightweight guardrail against accidental execution. It is **not** a comprehensive security sandbox or hardened isolation mechanism.

## Installation

Requires a Unix-like operating system. Windows is not supported.

### Nix

Build or run directly from the flake:

```bash
nix build
# or from GitHub:
nix profile install github:akirak/agent-wrapper
```

### Go

```bash
go install github.com/akirak/agent-wrapper@latest
```

If you use the `[sandbox.bubblewrap]` feature on Linux, ensure [`bwrap`](https://github.com/containers/bubblewrap) is installed and available in your `PATH`.

## Usage

```bash
agent-wrapper [-f CONFIG_FILE] COMMAND [ARGS]...
```

### Options

- `-f CONFIG_FILE`: Path to the TOML configuration file. If omitted, `agent-wrapper` reads `$XDG_CONFIG_HOME/agent-wrapper/config.toml` (falling back to `$HOME/.config/agent-wrapper/config.toml` when `XDG_CONFIG_HOME` is unset).

### Examples

Run a coding agent using the default configuration file:

```bash
AGENTS_ALLOW_RUN=1 agent-wrapper claude --resume
```

Run a command with an explicit configuration file:

```bash
agent-wrapper -f ~/my-agent-config.toml codex
```

You can also create shell aliases or wrapper scripts so that invoking your coding agent always passes through `agent-wrapper`:

```bash
alias claude='agent-wrapper claude'
```

## Configuration

By default, configuration is read from `$XDG_CONFIG_HOME/agent-wrapper/config.toml`.

### Example `config.toml`

```toml
[preconditions]
check_environment = true
allowed_working_directory_prefixes = ["/git"]

[sandbox.bubblewrap]
arguments = ["--bind", "$HOME", "$HOME", "--unshare-all"]

[environment]
CMD_API_KEY = { file = "/run/ageism/commandcode-api-key" }
```

### `[preconditions]`

Controls safety checks that must pass before the command is allowed to start.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `check_environment` | boolean | `false` | Enables environment and working directory checks. |
| `allowed_working_directory_prefixes` | array of strings | `[]` | List of allowed absolute directory paths. Required when `check_environment = true`. |

When `check_environment` is set to `true`, `agent-wrapper` refuses to start the command unless **both** of the following conditions are met:

1. **Environment opt-in:** The `AGENTS_ALLOW_RUN` environment variable is set to `"1"` (for example, via a per-project `.envrc` managed by [direnv](https://direnv.net/)).
2. **Working directory check:** The resolved real path (with all symbolic links evaluated) of the current working directory is equal to, or a subdirectory of, at least one path in `allowed_working_directory_prefixes`. Path matching is component-wise (for example, `/git/work` matches `/git`, whereas `/github` does not).

### `[environment]`

Loads environment variables from files before expanding sandbox arguments and executing the command. This is primarily intended for injecting API keys decrypted at runtime (e.g., via `agenix` or `sops-nix`).

Each entry maps an environment variable name to a table with a `file` key:

```toml
[environment]
ANTHROPIC_API_KEY = { file = "/run/secrets/anthropic-api-key" }
OPENAI_API_KEY = { file = "/run/secrets/openai-api-key" }
```

- Leading and trailing whitespace (including trailing newlines) is stripped from the file contents.
- If a configured file does not exist, it is not an error; the corresponding variable is unset, even if it was inherited from the parent process.
- Any other I/O error (such as insufficient permissions or the path pointing to a directory) causes `agent-wrapper` to abort with exit status `1`.

### `[sandbox.bubblewrap]` (Linux only)

When the `[sandbox.bubblewrap]` section is present, `agent-wrapper` executes the target command inside [Bubblewrap](https://github.com/containers/bubblewrap):

```bash
bwrap [ARGUMENTS...] COMMAND [ARGS...]
```

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `arguments` | array of strings | `[]` | Command-line arguments passed to `bwrap` before `COMMAND`. |

- **Environment variable expansion:** Any argument in `arguments` that begins with `$` (for example, `"$HOME"` or `"${XDG_RUNTIME_DIR}/bus"`) is expanded against the process environment (`os.ExpandEnv`) before `bwrap` is invoked. Arguments that do not begin with `$` are passed verbatim. Variables defined in `[environment]` are loaded prior to this expansion.
- **Disabling the sandbox:** Omit the `[sandbox.bubblewrap]` section entirely to run the command directly without Bubblewrap.
- **Other Unix-like platforms:** On Unix-like operating systems other than Linux, `[sandbox.bubblewrap]` is ignored with a warning to `stderr`, and the command is executed without a sandbox.

## Exit Status

On Unix-like systems, `agent-wrapper` replaces its own process with the target command via `execve(2)`, so signals and exit codes are handled transparently by the child process.

| Exit code | Meaning |
| --- | --- |
| `0` | The wrapped command exited successfully. |
| *N* | The exit status returned by the wrapped command when it fails. |
| `1` | Configuration error, failed precondition check, environment setup error, or missing `bwrap` binary. |
| `2` | Invalid command-line flags or missing `COMMAND`. |
| `125` | The target command could not be executed (e.g., not found in `PATH`). |

## Development

Run the test suite:

```bash
go test ./...
```

Build with Nix:

```bash
nix build   # or: nix build .#agent-wrapper
```

Format source files:

```bash
nix fmt
```

## License

[MIT](./LICENSE)
