package main

// lock.go — single-instance lock (issue #1 §8).
//
// The claim under test is a named mutex in the global namespace: a second
// invocation must NOT be able to become the primary. There is deliberately no
// Local\ fallback — a fallback would fake the claim (plan §2).

import (
	"io"
	"time"
)

// mutexName is the exact object name the T9 selftest asserts.
const mutexName = `Global\YandexPortable_SingleInstance`

// InstanceLock is the platform seam for the mutex + forwarding channel.
type InstanceLock interface {
	// Acquire reports whether THIS process became the primary. A nil error
	// with acquired=false means another instance owns the name.
	Acquire(name string) (acquired bool, err error)
	// Forward hands url to the running instance. delivered=false with a nil
	// error means no target answered.
	Forward(name string, url string) (delivered bool, err error)
	// Listen serves the forwarding channel until the stop func is called.
	Listen(name string, onURL func(url string)) (stop func() error, err error)
	Close() error
}

// Deps carries every platform/OS boundary the launcher crosses, so tests can
// run the whole selftest against fakes on any OS.
type Deps struct {
	Out            io.Writer
	Now            func() time.Time
	ExeDir         string
	Getenv         func(string) string
	UILanguage     func() uint16
	Lock           InstanceLock
	OpenPolicy     func() (RegistryView, error)
	NewPruneFS     func(dataDir string) PruneFS
	BrowserRunning func() bool
	Exec           func(exe string, args []string) (int, error)
}
