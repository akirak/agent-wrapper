package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"
)

// applyEnvironment sets environment variables from the files given in
// the [environment] section of the configuration file. Missing files
// are not an error; the corresponding variables are unset, even if inherited.
func applyEnvironment(sources map[string]EnvironmentSource) error {
	for name, source := range sources {
		if err := checkEnvName(name); err != nil {
			return fmt.Errorf("invalid environment variable name %q in the config file: %w", name, err)
		}

		data, err := os.ReadFile(source.File)
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				if err := os.Unsetenv(name); err != nil {
					return fmt.Errorf("unsetting the environment variable %s: %w", name, err)
				}
				continue
			}
			return fmt.Errorf("reading the value of the environment variable %s from %s: %w",
				name, source.File, err)
		}

		if err := os.Setenv(name, strings.TrimSpace(string(data))); err != nil {
			return fmt.Errorf("setting the environment variable %s: %w", name, err)
		}
	}
	return nil
}

func checkEnvName(name string) error {
	if name == "" {
		return errors.New("the name is empty")
	}
	if strings.ContainsAny(name, "=\x00") {
		return errors.New("the name contains a forbidden character")
	}
	return nil
}
