package main

import (
	"path/filepath"
	"strings"
	"testing"
)

func existsSet(paths ...string) func(string) bool {
	set := map[string]bool{}
	for _, p := range paths {
		set[p] = true
	}
	return func(p string) bool { return set[p] }
}

func TestResolveLayoutFromYandexDir(t *testing.T) {
	root := t.TempDir()
	appDir := filepath.Join(root, "Yandex")
	exe := filepath.Join(appDir, "browser.exe")
	l, err := ResolveLayout(appDir, existsSet(exe, filepath.Join(root, "Data")))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if l.AppDir != appDir || l.Root != root || l.BrowserExe != exe {
		t.Fatalf("layout = %+v want appDir=%s root=%s", l, appDir, root)
	}
}

func TestResolveLayoutFromPackageRoot(t *testing.T) {
	root := t.TempDir()
	appDir := filepath.Join(root, "Yandex")
	exe := filepath.Join(appDir, "browser.exe")
	l, err := ResolveLayout(root, existsSet(exe, filepath.Join(root, "Data")))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if l.AppDir != appDir || l.Root != root {
		t.Fatalf("layout = %+v want appDir=%s root=%s", l, appDir, root)
	}
}

func TestResolveLayoutWithoutBrowserFails(t *testing.T) {
	if _, err := ResolveLayout(t.TempDir(), existsSet()); err == nil {
		t.Fatal("missing browser.exe must be an error")
	}
}

func TestLaunchPlanPrefersVersionDll(t *testing.T) {
	root := t.TempDir()
	appDir := filepath.Join(root, "Yandex")
	exe := filepath.Join(appDir, "browser.exe")
	dll := filepath.Join(appDir, "version.dll")
	l, err := ResolveLayout(appDir, existsSet(exe, dll))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	p := BuildLaunchPlan(l, "", existsSet(exe, dll))
	if !p.UseVersionDll || p.Fallback {
		t.Fatalf("plan must prefer version.dll, got %+v", p)
	}
	for _, a := range p.Args {
		if strings.HasPrefix(a, "--user-data-dir") || strings.HasPrefix(a, "--disk-cache-dir") {
			t.Fatalf("version.dll path must not add portable flags, got %v", p.Args)
		}
	}
}

func TestLaunchPlanFallsBackWhenVersionDllMissing(t *testing.T) {
	root := t.TempDir()
	appDir := filepath.Join(root, "Yandex")
	exe := filepath.Join(appDir, "browser.exe")
	l, err := ResolveLayout(appDir, existsSet(exe))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	p := BuildLaunchPlan(l, "https://example.test/page", existsSet(exe))
	if p.UseVersionDll || !p.Fallback {
		t.Fatalf("plan must fall back, got %+v", p)
	}
	joined := strings.Join(p.Args, " ")
	wantData := "--user-data-dir " + filepath.Join(root, "Data")
	wantCache := "--disk-cache-dir " + filepath.Join(root, "Cache")
	if !strings.Contains(joined, wantData) {
		t.Fatalf("args %v missing %q", p.Args, wantData)
	}
	if !strings.Contains(joined, wantCache) {
		t.Fatalf("args %v missing %q", p.Args, wantCache)
	}
	if p.Args[len(p.Args)-1] != "https://example.test/page" {
		t.Fatalf("startup URL must be the last argument, got %v", p.Args)
	}
}

func TestLaunchPlanWithoutURLOmitsIt(t *testing.T) {
	root := t.TempDir()
	appDir := filepath.Join(root, "Yandex")
	exe := filepath.Join(appDir, "browser.exe")
	l, err := ResolveLayout(appDir, existsSet(exe))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	p := BuildLaunchPlan(l, "", existsSet(exe))
	for _, a := range p.Args {
		if strings.Contains(a, "://") {
			t.Fatalf("no URL requested but got %v", p.Args)
		}
	}
}
