package main

// launch.go — portable launch plan (issue #1 §4/§7: version.dll redirection
// with the explicit --user-data-dir/--disk-cache-dir fallback, spike P2/P2b).

import (
	"fmt"
	"path/filepath"
)

// Layout describes where the package keeps its browser and its portable dirs.
type Layout struct {
	AppDir     string // dir holding browser.exe
	Root       string // package root (sibling of Data\ and Cache\)
	BrowserExe string
}

// ResolveLayout accepts either the package root or the Yandex\ dir.
func ResolveLayout(appDirHint string, exists func(string) bool) (Layout, error) {
	hint := filepath.Clean(appDirHint)
	for _, cand := range []string{hint, filepath.Join(hint, "Yandex")} {
		exe := filepath.Join(cand, "browser.exe")
		if !exists(exe) {
			continue
		}
		l := Layout{AppDir: cand, BrowserExe: exe, Root: cand}
		if parent := filepath.Dir(cand); parent != cand {
			if filepath.Base(cand) == "Yandex" || exists(filepath.Join(parent, "Data")) {
				l.Root = parent
			}
		}
		return l, nil
	}
	return Layout{}, fmt.Errorf("browser.exe not found under %s", hint)
}

// LaunchPlan is the exact argv for browser.exe.
type LaunchPlan struct {
	Args          []string
	UseVersionDll bool // version.dll next to browser.exe relocates Data/Cache
	Fallback      bool // explicit --user-data-dir/--disk-cache-dir flags
}

// BuildLaunchPlan prefers version.dll and falls back to explicit flags when
// the DLL is missing.
func BuildLaunchPlan(l Layout, url string, exists func(string) bool) LaunchPlan {
	p := LaunchPlan{UseVersionDll: exists(filepath.Join(l.AppDir, "version.dll"))}
	p.Fallback = !p.UseVersionDll
	if p.Fallback {
		p.Args = append(p.Args,
			"--user-data-dir", filepath.Join(l.Root, "Data"),
			"--disk-cache-dir", filepath.Join(l.Root, "Cache"),
		)
	}
	if url != "" {
		p.Args = append(p.Args, url)
	}
	return p
}
