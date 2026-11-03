package main

import (
	"fmt"
	"os"

	toml "github.com/BurntSushi/toml"
)

// Config is the top-level structure of the TOML configuration file.
type Config struct {
	Preconditions PreconditionsConfig          `toml:"preconditions"`
	Sandbox       SandboxConfig                `toml:"sandbox"`
	Environment   map[string]EnvironmentSource `toml:"environment"`
}

// PreconditionsConfig controls the checks that block starting the agent.
type PreconditionsConfig struct {
	// CheckEnvironment enables the safety preconditions. When enabled,
	// the agent is only allowed to run if the AGENTS_ALLOW_RUN
	// environment variable is set to "1" and the current working
	// directory is under one of the allowed prefixes.
	CheckEnvironment bool `toml:"check_environment"`

	// AllowedWorkingDirectoryPrefixes is a list of absolute directory
	// paths. The real path of the current working directory must be
	// equal to, or a subdirectory of, one of them.
	AllowedWorkingDirectoryPrefixes []string `toml:"allowed_working_directory_prefixes"`
}

// SandboxConfig configures the runtime sandbox.
type SandboxConfig struct {
	// Bubblewrap holds the arguments passed to bwrap(1). It is nil
	// unless the [sandbox.bubblewrap] table is present in the
	// configuration file.
	Bubblewrap *BubblewrapConfig `toml:"bubblewrap"`
}

// BubblewrapConfig holds the configuration for running the agent inside
// a bubblewrap sandbox.
type BubblewrapConfig struct {
	// Arguments are passed to bwrap before the agent command. Each
	// argument starting with "$" is expanded as an environment
	// variable reference.
	Arguments []string `toml:"arguments"`
}

// EnvironmentSource describes where the value of an environment
// variable comes from.
type EnvironmentSource struct {
	// File is a path to a file whose (trimmed) contents become the
	// value of the environment variable. If the file does not exist,
	// the variable is unset, including any inherited value.
	File string `toml:"file"`
}

// loadConfig reads and parses a TOML configuration file.
func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading config file: %w", err)
	}

	var cfg Config
	if err := toml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing config file %s: %w", path, err)
	}
	return &cfg, nil
}
