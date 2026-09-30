//go:build windows

package main

// platform_windows.go — the real OS backends: the Global\ mutex, the named
// pipe forward channel, the HKCU policy view, the UI language and the
// "is browser.exe running" probe.

import (
	"bytes"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

var (
	modkernel32                  = windows.NewLazySystemDLL("kernel32.dll")
	procCreateMutexW             = modkernel32.NewProc("CreateMutexW")
	procSetLastError             = modkernel32.NewProc("SetLastError")
	procGetUserDefaultUILanguage = modkernel32.NewProc("GetUserDefaultUILanguage")
)

const forwardTimeout = 1500 * time.Millisecond

// createMutexW keeps the ERROR_ALREADY_EXISTS distinction. x/sys's own
// CreateMutex wrapper folds that case into a nil error, which would make the
// single-instance claim unfalsifiable.
func createMutexW(name string) (windows.Handle, bool, error) {
	p, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return 0, false, err
	}
	// CreateMutexW signals "already exists" through GetLastError while still
	// succeeding, and a stale value left by an earlier call would be read as a
	// false positive - clear the thread error state first.
	procSetLastError.Call(0)
	h, _, e1 := procCreateMutexW.Call(0, 1, uintptr(unsafe.Pointer(p)))
	handle := windows.Handle(h)
	if handle == 0 {
		if e1 != nil {
			return 0, false, e1
		}
		return 0, false, errors.New("CreateMutexW returned a null handle")
	}
	return handle, errors.Is(e1, windows.ERROR_ALREADY_EXISTS), nil
}

// pipePath derives the forwarding pipe name from the mutex name.
func pipePath(name string) string {
	base := name
	if i := strings.LastIndexByte(base, '\\'); i >= 0 {
		base = base[i+1:]
	}
	return `\\.\pipe\` + base
}

// windowsLock is the InstanceLock implementation.
type windowsLock struct {
	mu          sync.Mutex
	mutexHandle windows.Handle
	pipeHandle  windows.Handle
}

func newPlatformLock() InstanceLock { return &windowsLock{} }

func (l *windowsLock) Acquire(name string) (bool, error) {
	handle, alreadyExists, err := createMutexW(name)
	if err != nil {
		return false, err
	}
	if alreadyExists {
		_ = windows.CloseHandle(handle)
		return false, nil
	}
	l.mu.Lock()
	l.mutexHandle = handle
	l.mu.Unlock()
	return true, nil
}

func (l *windowsLock) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.mutexHandle == 0 {
		return nil
	}
	err := windows.CloseHandle(l.mutexHandle)
	l.mutexHandle = 0
	return err
}

// Listen serves one message at a time on the forwarding pipe until stop is
// called. stop closes the handle, which unblocks the serving goroutine.
func (l *windowsLock) Listen(name string, onURL func(string)) (func() error, error) {
	path, err := windows.UTF16PtrFromString(pipePath(name))
	if err != nil {
		return nil, err
	}
	handle, err := windows.CreateNamedPipe(
		path,
		windows.PIPE_ACCESS_DUPLEX|windows.FILE_FLAG_FIRST_PIPE_INSTANCE,
		windows.PIPE_TYPE_MESSAGE|windows.PIPE_READMODE_MESSAGE|windows.PIPE_WAIT,
		1, 4096, 4096, 0, nil,
	)
	if err != nil {
		return nil, fmt.Errorf("create forward pipe: %w", err)
	}
	l.mu.Lock()
	l.pipeHandle = handle
	l.mu.Unlock()

	stopCh := make(chan struct{})
	var once sync.Once
	stop := func() error {
		once.Do(func() {
			close(stopCh)
			l.mu.Lock()
			if l.pipeHandle != 0 {
				_ = windows.CloseHandle(l.pipeHandle)
				l.pipeHandle = 0
			}
			l.mu.Unlock()
		})
		return nil
	}

	go func() {
		for {
			err := windows.ConnectNamedPipe(handle, nil)
			if err != nil &&
				!errors.Is(err, windows.ERROR_PIPE_CONNECTED) &&
				!errors.Is(err, windows.ERROR_NO_DATA) {
				return // stop() closed the handle, or the pipe broke
			}
			if url := readPipeLine(handle); url != "" {
				onURL(url)
			}
			select {
			case <-stopCh:
				return
			default:
			}
		}
	}()
	return stop, nil
}

// Forward hands url to the listening primary, retrying while the primary is
// still between "mutex acquired" and "listener up".
func (l *windowsLock) Forward(name, url string) (bool, error) {
	path, err := windows.UTF16PtrFromString(pipePath(name))
	if err != nil {
		return false, err
	}
	deadline := time.Now().Add(forwardTimeout)
	for {
		h, err := windows.CreateFile(path, windows.GENERIC_WRITE, 0, nil, windows.OPEN_EXISTING, 0, 0)
		if err == nil {
			defer windows.CloseHandle(h)
			payload := append([]byte(url), '\n')
			var written uint32
			if werr := windows.WriteFile(h, payload, &written, nil); werr != nil {
				return false, fmt.Errorf("forward write: %w", werr)
			}
			return true, nil
		}
		if !errors.Is(err, windows.ERROR_FILE_NOT_FOUND) && !errors.Is(err, windows.ERROR_PIPE_BUSY) {
			return false, fmt.Errorf("forward connect: %w", err)
		}
		if time.Now().After(deadline) {
			return false, fmt.Errorf("no forwarding listener on %s", pipePath(name))
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func readPipeLine(h windows.Handle) string {
	var buf []byte
	tmp := make([]byte, 512)
	for len(buf) <= 64*1024 {
		var n uint32
		if err := windows.ReadFile(h, tmp, &n, nil); err != nil || n == 0 {
			return ""
		}
		buf = append(buf, tmp[:n]...)
		if i := bytes.IndexByte(buf, '\n'); i >= 0 {
			return strings.TrimSpace(string(buf[:i]))
		}
	}
	return ""
}

// ------------------------------------------------------------- registry --

// windowsPolicyView is the RegistryView over
// HKCU\Software\Policies\YandexBrowser.
type windowsPolicyView struct {
	key    registry.Key
	parent registry.Key
}

func openPolicyView() (RegistryView, error) {
	const access = registry.QUERY_VALUE | registry.SET_VALUE | registry.READ | registry.WRITE
	parent, _, err := registry.CreateKey(registry.CURRENT_USER, `Software\Policies`, access)
	if err != nil {
		return nil, fmt.Errorf("open HKCU\\Software\\Policies: %w", err)
	}
	key, _, err := registry.CreateKey(parent, "YandexBrowser", access)
	if err != nil {
		_ = parent.Close()
		return nil, fmt.Errorf("open HKCU\\Software\\Policies\\YandexBrowser: %w", err)
	}
	return &windowsPolicyView{key: key, parent: parent}, nil
}

func (v *windowsPolicyView) Get(name string) (uint32, bool, error) {
	val, _, err := v.key.GetIntegerValue(name)
	if errors.Is(err, registry.ErrNotExist) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return uint32(val), true, nil
}

func (v *windowsPolicyView) Set(name string, data uint32) error {
	return v.key.SetDWordValue(name, data)
}

func (v *windowsPolicyView) Delete(name string) error {
	err := v.key.DeleteValue(name)
	if errors.Is(err, registry.ErrNotExist) {
		return nil
	}
	return err
}

func (v *windowsPolicyView) ValueNames() ([]string, error) {
	return v.key.ReadValueNames(-1)
}

// Close releases the handles first: RegDeleteKey refuses to remove a key that
// is still open, so the empty-key removal has to happen afterwards.
func (v *windowsPolicyView) Close(deleteIfEmpty bool) error {
	var errs []error
	if err := v.key.Close(); err != nil {
		errs = append(errs, err)
	}
	if deleteIfEmpty {
		if err := registry.DeleteKey(v.parent, "YandexBrowser"); err != nil {
			errs = append(errs, err)
		}
	}
	if err := v.parent.Close(); err != nil {
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}

// ------------------------------------------------------------ OS probes --

func defaultUILanguage() uint16 {
	r, _, _ := procGetUserDefaultUILanguage.Call()
	return uint16(r)
}

// browserRunning reports whether any Chromium main process holds the profile.
// A running browser always wins over the prune.
func browserRunning() bool {
	for _, image := range []string{"browser.exe", "browser_proxy.exe"} {
		out, err := execTasklist(image)
		if err != nil {
			continue
		}
		if strings.Contains(strings.ToLower(out), strings.ToLower(image)) {
			return true
		}
	}
	return false
}

// execTasklist runs tasklist with an image filter. tasklist exits non-zero when
// the filter matches nothing, which is the same answer as "not running".
func execTasklist(image string) (string, error) {
	cmd := exec.Command("tasklist", "/FI", "IMAGENAME eq "+image)
	out, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return string(out), nil
		}
		return "", err
	}
	return string(out), nil
}
