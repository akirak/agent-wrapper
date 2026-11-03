package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
)

func TestHasPathPrefix(t *testing.T) {
	tests := []struct {
		dir    string
		prefix string
		want   bool
	}{
		{"/git/work", "/git", true},
		{"/git", "/git", true},
		{"/git/", "/git", true},
		{"/github", "/git", false},
		{"/git/work", "/git/work/project", false},
		{"/git/work", "/git/w", false},
		{"/tmp/x-y", "/tmp/x", false},
		{"/tmp/x/y", "/tmp/x/", true},
		{"/git/work", "/", true},
		{"/", "/", true},
		{"/", "/git", false},
	}

	for _, tt := range tests {
		if got := hasPathPrefix(tt.dir, tt.prefix); got != tt.want {
			t.Errorf("hasPathPrefix(%q, %q) = %v, want %v", tt.dir, tt.prefix, got, tt.want)
		}
	}
}

func TestLoadConfig(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.toml")

	content := `
[preconditions]
check_environment = true
allowed_working_directory_prefixes = [ "/git", "$HOME" ]

[sandbox.bubblewrap]
arguments = ["--bind", "$HOME", "$HOME", "--unshare-all"]

[environment]
CMD_API_KEY = { file = "/run/ageism/commandcode-api-key" }
`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}

	if !cfg.Preconditions.CheckEnvironment {
		t.Error("CheckEnvironment = false, want true")
	}
	if got := cfg.Preconditions.AllowedWorkingDirectoryPrefixes; len(got) != 2 || got[0] != "/git" || got[1] != "$HOME" {
		t.Errorf("AllowedWorkingDirectoryPrefixes = %v", got)
	}
	if cfg.Sandbox.Bubblewrap == nil {
		t.Fatal("Sandbox.Bubblewrap is nil, want present")
	}
	if got := cfg.Sandbox.Bubblewrap.Arguments; len(got) != 4 || got[0] != "--bind" || got[3] != "--unshare-all" {
		t.Errorf("Bubblewrap.Arguments = %v", got)
	}
	if got, ok := cfg.Environment["CMD_API_KEY"]; !ok || got.File != "/run/ageism/commandcode-api-key" {
		t.Errorf("Environment[CMD_API_KEY] = %+v", got)
	}
}

func TestLoadConfigWithoutSandbox(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.toml")
	if err := os.WriteFile(path, []byte("[preconditions]\ncheck_environment = false\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if cfg.Sandbox.Bubblewrap != nil {
		t.Errorf("Sandbox.Bubblewrap = %+v, want nil", cfg.Sandbox.Bubblewrap)
	}
}

func TestLoadConfigMissingFile(t *testing.T) {
	if _, err := loadConfig(filepath.Join(t.TempDir(), "absent.toml")); err == nil {
		t.Error("loadConfig on a missing file succeeded, want an error")
	}
}

func TestCheckPreconditions(t *testing.T) {
	t.Setenv("AGENTS_ALLOW_RUN", "")
	dir := t.TempDir()
	sub := filepath.Join(dir, "sub")
	if err := os.Mkdir(sub, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Chdir(sub)

	// Missing AGENTS_ALLOW_RUN.
	if err := checkPreconditions(PreconditionsConfig{
		CheckEnvironment:                true,
		AllowedWorkingDirectoryPrefixes: []string{dir},
	}); err == nil {
		t.Error("checkPreconditions succeeded without AGENTS_ALLOW_RUN, want an error")
	}

	t.Setenv("AGENTS_ALLOW_RUN", "1")

	// Empty list of allowed prefixes.
	if err := checkPreconditions(PreconditionsConfig{CheckEnvironment: true}); err == nil {
		t.Error("checkPreconditions succeeded with no allowed prefixes, want an error")
	}

	// Working directory outside the allowed prefixes.
	if err := checkPreconditions(PreconditionsConfig{
		CheckEnvironment:                true,
		AllowedWorkingDirectoryPrefixes: []string{filepath.Join(dir, "other")},
	}); err == nil {
		t.Error("checkPreconditions succeeded outside the allowed prefixes, want an error")
	}

	// Working directory inside an allowed prefix.
	if err := checkPreconditions(PreconditionsConfig{
		CheckEnvironment:                true,
		AllowedWorkingDirectoryPrefixes: []string{"/usr", dir},
	}); err != nil {
		t.Errorf("checkPreconditions failed inside %s: %v", dir, err)
	}

	// The filesystem root allows every working directory.
	if err := checkPreconditions(PreconditionsConfig{
		CheckEnvironment:                true,
		AllowedWorkingDirectoryPrefixes: []string{"/"},
	}); err != nil {
		t.Errorf("checkPreconditions failed with the root prefix: %v", err)
	}

	// Preconditions disabled.
	t.Setenv("AGENTS_ALLOW_RUN", "")
	if err := checkPreconditions(PreconditionsConfig{CheckEnvironment: false}); err != nil {
		t.Errorf("checkPreconditions failed when disabled: %v", err)
	}
}

func TestApplyEnvironment(t *testing.T) {
	t.Setenv("AW_TEST_TOKEN", "inherited-token")
	t.Setenv("AW_TEST_ABSENT", "inherited-token")
	dir := t.TempDir()
	tokenFile := filepath.Join(dir, "token")
	if err := os.WriteFile(tokenFile, []byte("  secret-token-123\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	sources := map[string]EnvironmentSource{
		"AW_TEST_TOKEN":  {File: tokenFile},
		"AW_TEST_ABSENT": {File: filepath.Join(dir, "missing")},
	}

	if err := applyEnvironment(sources); err != nil {
		t.Fatalf("applyEnvironment: %v", err)
	}

	if got := os.Getenv("AW_TEST_TOKEN"); got != "secret-token-123" {
		t.Errorf("AW_TEST_TOKEN = %q, want %q", got, "secret-token-123")
	}
	if got, ok := os.LookupEnv("AW_TEST_ABSENT"); ok {
		t.Errorf("AW_TEST_ABSENT = %q, want unset", got)
	}

	if err := applyEnvironment(map[string]EnvironmentSource{"BAD=NAME": {File: tokenFile}}); err == nil {
		t.Error("applyEnvironment accepted a variable name containing \"=\", want an error")
	}
	if err := applyEnvironment(map[string]EnvironmentSource{"AW_TEST_ERR": {File: dir}}); err == nil {
		t.Error("applyEnvironment succeeded when reading a directory, want an error")
	}
}

func TestBuildArgvWithoutSandbox(t *testing.T) {
	argv, err := buildArgv(SandboxConfig{}, "claude", []string{"--foo", "bar"})
	if err != nil {
		t.Fatalf("buildArgv: %v", err)
	}
	if len(argv) != 3 || argv[0] != "claude" || argv[1] != "--foo" || argv[2] != "bar" {
		t.Errorf("argv = %v", argv)
	}
}

func TestBuildArgvWithBubblewrap(t *testing.T) {
	t.Setenv("AW_TEST_HOME", "/home/user")

	// Skip when bwrap is unavailable (e.g. in a Nix build sandbox),
	// before buildArgv looks it up.
	bwrapPath, err := exec.LookPath("bwrap")
	if err != nil {
		t.Skipf("bwrap is not available: %v", err)
	}

	sandbox := SandboxConfig{Bubblewrap: &BubblewrapConfig{
		Arguments: []string{"--bind", "$AW_TEST_HOME", "$AW_TEST_HOME", "--unshare-all", "no$expansion", "${AW_TEST_HOME}/x"},
	}}

	argv, err := buildArgv(sandbox, "claude", []string{"--verbose"})
	if err != nil {
		t.Fatalf("buildArgv: %v", err)
	}

	want := []string{
		bwrapPath,
		"--bind", "/home/user", "/home/user",
		"--unshare-all",
		"no$expansion",
		"/home/user/x",
		"claude", "--verbose",
	}
	if len(argv) != len(want) {
		t.Fatalf("argv = %v, want %v", argv, want)
	}
	for i := range want {
		if argv[i] != want[i] {
			t.Errorf("argv[%d] = %q, want %q", i, argv[i], want[i])
		}
	}
}

func TestDefaultConfigPath(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", "/xdg")
	t.Setenv("HOME", "/home/user")
	if got, err := defaultConfigPath(); err != nil || got != "/xdg/agent-wrapper/config.toml" {
		t.Errorf("defaultConfigPath() = %q, %v", got, err)
	}

	t.Setenv("XDG_CONFIG_HOME", "")
	if got, err := defaultConfigPath(); err != nil || got != "/home/user/.config/agent-wrapper/config.toml" {
		t.Errorf("defaultConfigPath() = %q, %v", got, err)
	}

	t.Setenv("HOME", "")
	if _, err := defaultConfigPath(); err == nil {
		t.Error("defaultConfigPath succeeded without HOME, want an error")
	}
}

func TestRun(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.toml")
	if err := os.WriteFile(configPath, []byte(""), 0o600); err != nil {
		t.Fatal(err)
	}

	if code := run([]string{"-f", configPath}); code != 2 {
		t.Errorf("run without a command = %d, want 2", code)
	}
	if code := run([]string{"-f", filepath.Join(dir, "missing.toml"), "true"}); code != 1 {
		t.Errorf("run with a missing config file = %d, want 1", code)
	}
	if code := run([]string{"-f", configPath, "definitely-not-a-command-xyz"}); code != 125 {
		t.Errorf("run with an unknown command = %d, want 125", code)
	}
}

// TestEndToEnd builds the agent-wrapper binary and exercises it as an
// external process. The success path cannot be tested in-process
// because execAgent replaces the current process with execve(2).
func TestEndToEnd(t *testing.T) {
	if _, err := exec.LookPath("sh"); err != nil {
		t.Skipf("sh is not available: %v", err)
	}

	bin := filepath.Join(t.TempDir(), "agent-wrapper")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("building agent-wrapper: %v\n%s", err, out)
	}

	workDir := t.TempDir()
	t.Chdir(workDir)

	tokenFile := filepath.Join(workDir, "token")
	if err := os.WriteFile(tokenFile, []byte("e2e-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	configPath := filepath.Join(workDir, "config.toml")
	config := "[preconditions]\n" +
		"check_environment = true\n" +
		"allowed_working_directory_prefixes = [\"" + workDir + "\"]\n" +
		"[environment]\n" +
		"AW_E2E_TOKEN = { file = \"" + tokenFile + "\" }\n" +
		"AW_E2E_ABSENT = { file = \"" + filepath.Join(workDir, "missing") + "\" }\n"

	runWrapped := func(t *testing.T, extraConfig, command string, args ...string) (string, int) {
		t.Helper()
		if err := os.WriteFile(configPath, []byte(config+extraConfig), 0o600); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command(bin, append([]string{"-f", configPath, command}, args...)...)
		cmd.Env = append(os.Environ(), "AGENTS_ALLOW_RUN=1")
		out, err := cmd.Output()
		code := 0
		if err != nil {
			var exitErr *exec.ExitError
			if !errors.As(err, &exitErr) {
				t.Fatalf("running agent-wrapper: %v\n%s", err, out)
			}
			code = exitErr.ExitCode()
		}
		return string(out), code
	}

	t.Run("precondition blocks without AGENTS_ALLOW_RUN", func(t *testing.T) {
		if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command(bin, "-f", configPath, "true")
		cmd.Env = append(os.Environ(), "AGENTS_ALLOW_RUN=")
		if err := cmd.Run(); err == nil {
			t.Error("the wrapper ran the agent without AGENTS_ALLOW_RUN, want refusal")
		}
	})

	t.Run("environment variables are set from files", func(t *testing.T) {
		t.Setenv("AW_E2E_ABSENT", "inherited-token")
		out, code := runWrapped(t, "", "sh", "-c", `printf '%s %s' "$AW_E2E_TOKEN" "${AW_E2E_ABSENT-unset}"`)
		if code != 0 {
			t.Fatalf("exit code = %d", code)
		}
		if want := "e2e-token unset"; out != want {
			t.Errorf("output = %q, want %q", out, want)
		}
	})

	t.Run("exit status is propagated", func(t *testing.T) {
		if _, code := runWrapped(t, "", "sh", "-c", "exit 42"); code != 42 {
			t.Errorf("exit code = %d, want 42", code)
		}
	})

	t.Run("bubblewrap sandbox", func(t *testing.T) {
		if runtime.GOOS != "linux" {
			t.Skip("bubblewrap is only used on Linux")
		}
		if _, err := exec.LookPath("bwrap"); err != nil {
			t.Skipf("bwrap is not available: %v", err)
		}

		extraConfig := "[sandbox.bubblewrap]\n" +
			"arguments = [\"--unshare-all\", \"--proc\", \"/proc\", \"--dev\", \"/dev\", \"--ro-bind\", \"/\", \"/\"]\n"
		out, code := runWrapped(t, extraConfig, "sh", "-c", `printf '%s' "$AW_E2E_TOKEN"`)
		if code != 0 {
			t.Fatalf("exit code = %d, want 0", code)
		}
		if want := "e2e-token"; out != want {
			t.Errorf("output = %q, want %q", out, want)
		}
	})
}
