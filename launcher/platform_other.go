//go:build !windows

package main

// platform_other.go — stubs for the OS seams when the launcher is built for a
// non-Windows host (unit tests inject fakes; this only keeps `go test ./...`
// and `go vet ./...` honest on the CI dev box).
//
// A real run here must fail loudly instead of pretending the claim held: a
// Local\ style shortcut or a silent no-op would fake the single-instance and
// HKCU claims.

import (
	"fmt"
	"runtime"
)

func newPlatformLock() InstanceLock { return unsupportedLock{} }

type unsupportedLock struct{}

func (unsupportedLock) Acquire(string) (bool, error) {
	return false, fmt.Errorf("single-instance mutex needs Windows (running on %s)", runtime.GOOS)
}

func (unsupportedLock) Forward(string, string) (bool, error) {
	return false, fmt.Errorf("forward channel needs Windows (running on %s)", runtime.GOOS)
}

func (unsupportedLock) Listen(string, func(string)) (func() error, error) {
	return nil, fmt.Errorf("forward channel needs Windows (running on %s)", runtime.GOOS)
}

func (unsupportedLock) Close() error { return nil }

func openPolicyView() (RegistryView, error) {
	return nil, fmt.Errorf("HKCU policy view needs Windows (running on %s)", runtime.GOOS)
}

func defaultUILanguage() uint16 { return 0 }

func browserRunning() bool { return false }
