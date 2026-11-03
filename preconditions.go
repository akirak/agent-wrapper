package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// checkPreconditions blocks starting the agent unless the configured
// conditions are met. It returns nil when the agent is allowed to run.
func checkPreconditions(cfg PreconditionsConfig) error {
	if !cfg.CheckEnvironment {
		return nil
	}

	if os.Getenv("AGENTS_ALLOW_RUN") != "1" {
		return errors.New("refusing to run the agent: AGENTS_ALLOW_RUN is not set to \"1\".\n" +
			"If you really want to run an agent, set AGENTS_ALLOW_RUN=1 in the environment.")
	}

	if len(cfg.AllowedWorkingDirectoryPrefixes) == 0 {
		return errors.New("refusing to run the agent: " +
			"no allowed working directory prefixes are configured in the config file")
	}

	cwd, err := realWorkingDirectory()
	if err != nil {
		return fmt.Errorf("resolving the working directory: %w", err)
	}

	for _, prefix := range cfg.AllowedWorkingDirectoryPrefixes {
		if hasPathPrefix(cwd, prefix) {
			return nil
		}
	}

	return fmt.Errorf("refusing to run the agent: %s is not under any of the allowed working directory prefixes",
		cwd)
}

// realWorkingDirectory returns the real path of the current working
// directory, with all symbolic links resolved.
func realWorkingDirectory() (string, error) {
	cwd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	real, err := filepath.EvalSymlinks(cwd)
	if err != nil {
		return "", err
	}
	return filepath.Abs(real)
}

// hasPathPrefix reports whether dir is prefix itself or a directory
// inside prefix. The comparison is component-wise, so that "/git/work"
// does not match the prefix "/git/w".
func hasPathPrefix(dir, prefix string) bool {
	prefix = filepath.Clean(prefix)
	dir = filepath.Clean(dir)
	if dir == prefix {
		return true
	}
	if !strings.HasSuffix(prefix, string(filepath.Separator)) {
		prefix += string(filepath.Separator)
	}
	return strings.HasPrefix(dir, prefix)
}
