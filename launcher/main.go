package main

// main.go — process entry point: wire the platform backends and run one
// launcher invocation.

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

func main() {
	os.Exit(NewApp(platformDeps()).Run(os.Args[1:]))
}

func platformDeps() Deps {
	return Deps{
		Out:            os.Stdout,
		Now:            time.Now,
		Getenv:         os.Getenv,
		ExeDir:         exeDir(),
		UILanguage:     defaultUILanguage,
		Lock:           newPlatformLock(),
		OpenPolicy:     openPolicyView,
		NewPruneFS:     func(dir string) PruneFS { return NewOSPruneFS(dir) },
		BrowserRunning: browserRunning,
		Exec:           runAndWait,
	}
}

func exeDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(exe)
}

// runAndWait spawns the browser, inherits its stdio and waits for it, so the
// policy/prune cleanup only happens once the window is gone.
func runAndWait(exe string, args []string) (int, error) {
	cmd := exec.Command(exe, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	err := cmd.Run()
	if err == nil {
		return 0, nil
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode(), nil
	}
	return -1, err
}
