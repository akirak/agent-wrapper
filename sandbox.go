package main

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
)

// buildArgv constructs the argument vector for the agent process. On
// Linux, when the [sandbox.bubblewrap] section is present in the
// configuration file, the agent is run inside a bwrap(1) sandbox with
// the configured arguments. Otherwise the agent command is run as-is.
//
// Environment variables are applied (see applyEnvironment) before this
// function is called, so that they are visible both to the expansion of
// "$"-prefixed sandbox arguments and to the agent itself.
func buildArgv(sandbox SandboxConfig, command string, args []string) ([]string, error) {
	if sandbox.Bubblewrap == nil {
		return append([]string{command}, args...), nil
	}

	if runtime.GOOS != "linux" {
		fmt.Fprintf(os.Stderr,
			"agent-wrapper: warning: the bubblewrap sandbox is not supported on %s; running %s without a sandbox\n",
			runtime.GOOS, command)
		return append([]string{command}, args...), nil
	}

	bwrap, err := exec.LookPath("bwrap")
	if err != nil {
		return nil, fmt.Errorf("bwrap was configured but is not available: %w", err)
	}

	argv := []string{bwrap}
	for _, arg := range sandbox.Bubblewrap.Arguments {
		// Arguments prefixed with "$" are expanded as environment
		// variable references, e.g. "$HOME" or "${HOME}".
		if strings.HasPrefix(arg, "$") {
			arg = os.ExpandEnv(arg)
		}
		argv = append(argv, arg)
	}
	return append(append(argv, command), args...), nil
}
