package main

// prune.go — cache prune (issue #1 §7, T7 volatile-dir list).
//
// state.json at the package root records the last prune time. When its mtime
// is at least --prune-days old (default 7) we delete exactly the T7 volatile
// dirs under Data\ — the ones a relaunch proved it recreates — and then stamp
// state.json. A fresh state.json is the fast skip path; a running browser
// always wins and aborts the prune.

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"
)

const defaultPruneDays = 7

// volatileDirs mirrors the T7 probe's delete list (slash-separated, relative
// to Data\). Profile files are never listed here.
var volatileDirs = []string{
	"GPUCache",
	"ShaderCache",
	"GrShaderCache",
	"DawnCache",
	"Default/Cache",
	"Default/Code Cache",
	"Default/Service Worker/CacheStorage",
	"Crashpad",
}

const browserMetricsPrefix = "BrowserMetrics"

// PruneDecision explains why a prune does or does not run.
type PruneDecision struct {
	Stale  bool
	Age    time.Duration
	MaxAge time.Duration
	Reason string
}

func EvaluatePrune(exists bool, age, maxAge time.Duration) PruneDecision {
	if !exists {
		return PruneDecision{Stale: true, MaxAge: maxAge, Reason: "state.json missing (never pruned)"}
	}
	d := PruneDecision{Age: age, MaxAge: maxAge}
	if age >= maxAge {
		d.Stale = true
		d.Reason = fmt.Sprintf("state.json age %s >= %s", age.Round(time.Hour), maxAge)
		return d
	}
	d.Reason = fmt.Sprintf("state.json age %s < %s", age.Round(time.Minute), maxAge)
	return d
}

// PruneFS is the filesystem seam (unit tests use an in-memory map).
type PruneFS interface {
	DataDir() string
	Exists(rel string) bool
	RemoveAll(rel string) error
	List(prefix string) ([]string, error)
}

// RunPrune deletes the T7 volatile dirs that exist and returns what went.
func RunPrune(fs PruneFS) ([]string, error) {
	var removed []string
	for _, rel := range volatileDirs {
		if !fs.Exists(rel) {
			continue
		}
		if err := fs.RemoveAll(rel); err != nil {
			return removed, fmt.Errorf("prune %s: %w", rel, err)
		}
		removed = append(removed, rel)
	}
	metrics, err := fs.List(browserMetricsPrefix)
	if err != nil {
		return removed, fmt.Errorf("prune list %s*: %w", browserMetricsPrefix, err)
	}
	sort.Strings(metrics)
	for _, rel := range metrics {
		if err := fs.RemoveAll(rel); err != nil {
			return removed, fmt.Errorf("prune %s: %w", rel, err)
		}
		removed = append(removed, rel)
	}
	return removed, nil
}

// StateAge reads state.json's age. A missing file is not an error: it means
// the package has never pruned.
func StateAge(path string, now time.Time) (time.Duration, bool, error) {
	fi, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return now.Sub(fi.ModTime()), true, nil
}

// WriteState stamps state.json at t (content is informational; mtime decides).
func WriteState(path string, t time.Time) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(path, []byte(fmt.Sprintf("{\n  \"pruned_at\": %q\n}\n", t.UTC().Format(time.RFC3339))), 0o644); err != nil {
		return err
	}
	return os.Chtimes(path, t, t)
}

// OSPruneFS is the real PruneFS rooted at Data\.
type OSPruneFS struct {
	dataDir string
}

func NewOSPruneFS(dataDir string) *OSPruneFS { return &OSPruneFS{dataDir: dataDir} }

func (f *OSPruneFS) DataDir() string { return f.dataDir }

func (f *OSPruneFS) path(rel string) string {
	return filepath.Join(f.dataDir, filepath.FromSlash(rel))
}

func (f *OSPruneFS) Exists(rel string) bool {
	_, err := os.Stat(f.path(rel))
	return err == nil
}

func (f *OSPruneFS) RemoveAll(rel string) error { return os.RemoveAll(f.path(rel)) }

func (f *OSPruneFS) List(prefix string) ([]string, error) {
	entries, err := os.ReadDir(f.dataDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var out []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if len(e.Name()) >= len(prefix) && e.Name()[:len(prefix)] == prefix {
			out = append(out, e.Name())
		}
	}
	return out, nil
}
