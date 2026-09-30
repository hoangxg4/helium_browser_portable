package main

// prune_test.go — age calculation and the T7 volatile-dir prune plan.
// T7 verdict lists the dirs that a relaunch must be able to recreate, so
// the launcher may only delete exactly those, and only when state.json says
// the last prune is older than the configured max age.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type fakePruneFS struct {
	dataDir string
	dirs    map[string]bool // rel path (slash) -> exists
	removed []string
	listed  []string
}

func newFakePruneFS(rels ...string) *fakePruneFS {
	fs := &fakePruneFS{dataDir: "Data", dirs: map[string]bool{}}
	for _, r := range rels {
		fs.dirs[r] = true
	}
	return fs
}

func (f *fakePruneFS) DataDir() string { return f.dataDir }
func (f *fakePruneFS) Exists(rel string) bool {
	return f.dirs[rel]
}
func (f *fakePruneFS) RemoveAll(rel string) error {
	if !f.dirs[rel] {
		return os.ErrNotExist
	}
	delete(f.dirs, rel)
	f.removed = append(f.removed, rel)
	return nil
}
func (f *fakePruneFS) List(prefix string) ([]string, error) {
	var out []string
	for rel := range f.dirs {
		if strings.Contains(rel, "/") {
			continue // only direct children of Data\ match BrowserMetrics-*
		}
		if strings.HasPrefix(rel, prefix) {
			out = append(out, rel)
		}
	}
	return out, nil
}

func TestEvaluatePruneFreshStateSkips(t *testing.T) {
	d := EvaluatePrune(true, 24*time.Hour, 7*24*time.Hour)
	if d.Stale {
		t.Fatalf("fresh state.json must take the fast skip path, got %+v", d)
	}
}

func TestEvaluatePruneStaleStateRuns(t *testing.T) {
	d := EvaluatePrune(true, 8*24*time.Hour, 7*24*time.Hour)
	if !d.Stale {
		t.Fatalf("state older than max age must prune, got %+v", d)
	}
}

func TestEvaluatePruneMissingStateRuns(t *testing.T) {
	d := EvaluatePrune(false, 0, 7*24*time.Hour)
	if !d.Stale {
		t.Fatalf("a package that never pruned must prune, got %+v", d)
	}
	if d.Reason == "" {
		t.Fatal("decision must carry a reason for the log line")
	}
}

func TestEvaluatePruneExactBoundaryIsStale(t *testing.T) {
	d := EvaluatePrune(true, 7*24*time.Hour, 7*24*time.Hour)
	if !d.Stale {
		t.Fatalf("age == max age must count as stale, got %+v", d)
	}
}

func TestStateAgeUsesModTime(t *testing.T) {
	p := filepath.Join(t.TempDir(), "state.json")
	if err := os.WriteFile(p, []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-30 * 24 * time.Hour)
	if err := os.Chtimes(p, old, old); err != nil {
		t.Fatal(err)
	}
	age, exists, err := StateAge(p, time.Now())
	if err != nil || !exists {
		t.Fatalf("StateAge = %v,%v,%v", age, exists, err)
	}
	if age < 29*24*time.Hour || age > 31*24*time.Hour {
		t.Fatalf("age = %v want ~720h", age)
	}
}

func TestStateAgeMissingFile(t *testing.T) {
	_, exists, err := StateAge(filepath.Join(t.TempDir(), "absent.json"), time.Now())
	if err != nil {
		t.Fatalf("missing state.json is not an error: %v", err)
	}
	if exists {
		t.Fatal("missing state.json must report exists=false")
	}
}

func TestRunPruneRemovesExactlyT7VolatileDirs(t *testing.T) {
	fs := newFakePruneFS(
		"GPUCache", "ShaderCache", "GrShaderCache", "DawnCache",
		"Default/Cache", "Default/Code Cache", "Default/Service Worker/CacheStorage", "Crashpad",
		"Default/Preferences", "Local State", // never touched
	)
	removed, err := RunPrune(fs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(removed) != 8 {
		t.Fatalf("removed %d dirs, want 8: %v", len(removed), removed)
	}
	if !fs.dirs["Default/Preferences"] || !fs.dirs["Local State"] {
		t.Fatalf("profile files must survive the prune, dirs=%v", fs.dirs)
	}
	for _, want := range volatileDirs {
		if _, ok := fs.dirs[want]; ok {
			t.Errorf("%s should have been removed", want)
		}
	}
}

func TestRunPruneSkipsAbsentDirs(t *testing.T) {
	fs := newFakePruneFS("GPUCache")
	removed, err := RunPrune(fs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(removed) != 1 || removed[0] != "GPUCache" {
		t.Fatalf("removed = %v want [GPUCache]", removed)
	}
}

func TestRunPruneRemovesBrowserMetricsDirs(t *testing.T) {
	fs := newFakePruneFS("BrowserMetrics-Crash-abc", "BrowserMetrics-foo", "Keep")
	removed, err := RunPrune(fs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(removed) != 2 {
		t.Fatalf("removed = %v want both BrowserMetrics dirs", removed)
	}
	if !fs.dirs["Keep"] {
		t.Fatal("unrelated dir must survive")
	}
}
