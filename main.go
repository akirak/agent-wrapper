// Command agent-wrapper wraps a coding agent command with safety
// preconditions, an optional bubblewrap sandbox, and environment
// variables loaded from files (e.g. API tokens).
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

const usage = `usage: agent-wrapper [-f CONFIG_FILE] COMMAND [ARGS]...

Run COMMAND (typically a coding agent) after applying the settings in
CONFIG_FILE (default: $XDG_CONFIG_HOME/agent-wrapper/config.toml).
`

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	fs := flag.NewFlagSet("agent-wrapper", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	fs.Usage = func() { fmt.Fprint(os.Stderr, usage) }

	configPath := fs.String("f", "", "path to the configuration file")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	if fs.NArg() == 0 {
		fs.Usage()
		return 2
	}
	command := fs.Arg(0)
	rest := fs.Args()[1:]

	if *configPath == "" {
		p, err := defaultConfigPath()
		if err != nil {
			fmt.Fprintf(os.Stderr, "agent-wrapper: %v\n", err)
			return 1
		}
		*configPath = p
	}

	cfg, err := loadConfig(*configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "agent-wrapper: %v\n", err)
		return 1
	}

	if err := checkPreconditions(cfg.Preconditions); err != nil {
		fmt.Fprintf(os.Stderr, "agent-wrapper: %v\n", err)
		return 1
	}

	if err := applyEnvironment(cfg.Environment); err != nil {
		fmt.Fprintf(os.Stderr, "agent-wrapper: %v\n", err)
		return 1
	}

	argv, err := buildArgv(cfg.Sandbox, command, rest)
	if err != nil {
		fmt.Fprintf(os.Stderr, "agent-wrapper: %v\n", err)
		return 1
	}

	if err := execAgent(argv); err != nil {
		fmt.Fprintf(os.Stderr, "agent-wrapper: %v\n", err)
		return 125
	}
	return 0
}

// defaultConfigPath returns the fallback configuration file path,
// i.e. $XDG_CONFIG_HOME/agent-wrapper/config.toml.
func defaultConfigPath() (string, error) {
	dir := os.Getenv("XDG_CONFIG_HOME")
	if dir == "" {
		home := os.Getenv("HOME")
		if home == "" {
			return "", errors.New("neither XDG_CONFIG_HOME nor HOME is set; specify a config file with -f")
		}
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "agent-wrapper", "config.toml"), nil
}
