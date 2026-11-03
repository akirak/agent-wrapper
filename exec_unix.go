//go:build unix

package main

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"
)

// execAgent replaces the current process with the given command. On
// Unix-like systems this uses execve(2), so the agent process directly
// inherits the terminal, the exit status, and the signals sent to it.
func execAgent(argv []string) error {
	path, err := exec.LookPath(argv[0])
	if err != nil {
		return err
	}
	if err := syscall.Exec(path, argv, os.Environ()); err != nil {
		return fmt.Errorf("exec %s: %w", argv[0], err)
	}
	return nil
}
