package main

// app_test.go — the T9 selftest contract the CI driver asserts against.

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// ------------------------------------------------------------------ fakes --

type fakeLock struct {
	acquired     bool
	acquireErr   error
	acquireCalls int
	names        []string
	forwarded    []string
	forwardOK    bool
	forwardErr   error
	listenErr    error
	listenCalls  int
	deliver      string // URL handed to the primary as soon as it starts listening
	onURL        func(string)
	stopped      bool
}

func (f *fakeLock) Acquire(name string) (bool, error) {
	f.acquireCalls++
	f.names = append(f.names, name)
	return f.acquired, f.acquireErr
}

func (f *fakeLock) Forward(_, url string) (bool, error) {
	f.forwarded = append(f.forwarded, url)
	return f.forwardOK, f.forwardErr
}

func (f *fakeLock) Listen(_ string, onURL func(string)) (func() error, error) {
	f.listenCalls++
	f.onURL = onURL
	if f.listenErr != nil {
		return nil, f.listenErr
	}
	if f.deliver != "" {
		onURL(f.deliver)
	}
	return func() error { f.stopped = true; return nil }, nil
}

func (f *fakeLock) Close() error { return nil }

type testPkg struct {
	root   string
	appDir string
	exe    string
}

func newTestPkg(t *testing.T, withDLL bool) *testPkg {
	t.Helper()
	root := t.TempDir()
	appDir := filepath.Join(root, "Yandex")
	if err := os.MkdirAll(appDir, 0o755); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(appDir, "browser.exe")
	if err := os.WriteFile(exe, []byte("MZ"), 0o755); err != nil {
		t.Fatal(err)
	}
	if withDLL {
		if err := os.WriteFile(filepath.Join(appDir, "version.dll"), []byte("dll"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(root, "Data"), 0o755); err != nil {
		t.Fatal(err)
	}
	return &testPkg{root: root, appDir: appDir, exe: exe}
}

func (p *testPkg) staleState(t *testing.T, age time.Duration) {
	t.Helper()
	path := filepath.Join(p.root, "state.json")
	if err := os.WriteFile(path, []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	when := time.Now().Add(-age)
	if err := os.Chtimes(path, when, when); err != nil {
		t.Fatal(err)
	}
}

func (p *testPkg) mkdir(t *testing.T, rel string) string {
	t.Helper()
	full := filepath.Join(p.root, "Data", filepath.FromSlash(rel))
	if err := os.MkdirAll(full, 0o755); err != nil {
		t.Fatal(err)
	}
	return full
}

func writeFindings(t *testing.T, line string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "issue1-claims-findings.md")
	body := "# findings\n\nsome prose\n"
	if line != "" {
		body += line + "\n"
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func writeDebloater(t *testing.T) string {
	t.Helper()
	return writeDebloaterIn(t, t.TempDir())
}

// writeDebloaterIn drops the shipped file where the package really puts it:
// beside browser.exe (README: Yandex\debloater.reg).
func writeDebloaterIn(t *testing.T, dir string) string {
	t.Helper()
	path := filepath.Join(dir, "debloater.reg")
	body := "Windows Registry Editor Version 5.00\n\n" +
		"[HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\YandexBrowser]\n" +
		"\"StatisticsReporting\"=dword:00000000\n" +
		"\"YandexAliceMsgDisable\"=dword:00000001\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

type testEnv struct {
	deps    Deps
	out     *bytes.Buffer
	lock    *fakeLock
	view    *fakeRegistryView
	execExe string
	execArg []string
	execRet int
	running bool
}

func newTestEnv(t *testing.T, p *testPkg) *testEnv {
	t.Helper()
	env := &testEnv{out: &bytes.Buffer{}, lock: &fakeLock{acquired: true}, execRet: 0}
	env.view = newFakeRegistryView(nil)
	env.deps = Deps{
		Out:        env.out,
		Now:        time.Now,
		ExeDir:     p.appDir,
		Getenv:     func(string) string { return "" },
		UILanguage: func() uint16 { return 0x09 }, // en-US
		Lock:       env.lock,
		OpenPolicy: func() (RegistryView, error) { return env.view, nil },
		NewPruneFS: func(dir string) PruneFS { return NewOSPruneFS(dir) },
		BrowserRunning: func() bool {
			return env.running
		},
		Exec: func(exe string, args []string) (int, error) {
			env.execExe, env.execArg = exe, args
			return env.execRet, nil
		},
	}
	return env
}

func (e *testEnv) run(args ...string) int {
	return NewApp(e.deps).Run(args)
}

func (e *testEnv) outText() string { return e.out.String() }

// ------------------------------------------------------------- selftest --

func TestSelftestMutexCreateErrorFailsWithExactVerdictLine(t *testing.T) {
	p := newTestPkg(t, true)
	env := newTestEnv(t, p)
	env.lock.acquireErr = errors.New("boom")

	code := env.run("--selftest", "--dry-run", "--lang", "en",
		"--findings", writeFindings(t, sampleIgnored), "--debloater", writeDebloater(t))

	if code == 0 {
		t.Fatal("a mutex create error must fail the selftest")
	}
	if !strings.Contains(env.outText(), "T9 verdict: FAIL — mutex create error: boom") {
		t.Fatalf("missing the exact FAIL contract line, output:\n%s", env.outText())
	}
	if env.lock.acquireCalls != 1 {
		t.Fatalf("no fallback retry allowed (a Local\\ fallback would fake the claim), calls=%d", env.lock.acquireCalls)
	}
	// Pin the literal: the log line is a static string, so only the name handed
	// to Acquire proves which namespace was really requested.
	if env.lock.names[0] != `Global\YandexPortable_SingleInstance` {
		t.Fatalf("acquired %q want %q", env.lock.names[0], `Global\YandexPortable_SingleInstance`)
	}
}

func TestSelftestPassPathCoversMutexModePruneAndDll(t *testing.T) {
	p := newTestPkg(t, true)
	p.staleState(t, 30*24*time.Hour)
	gpu := p.mkdir(t, "GPUCache")
	env := newTestEnv(t, p)

	code := env.run("--selftest", "--dry-run", "--lang", "en",
		"--findings", writeFindings(t, sampleIgnored), "--debloater", writeDebloater(t))

	if code != 0 {
		t.Fatalf("selftest exit = %d, output:\n%s", code, env.outText())
	}
	for _, want := range []string{
		"mutex: acquired Global\\YandexPortable_SingleInstance",
		"mode: skip - T1 verdict: IGNORED",
		"prune: executed",
		"launch: version.dll next to browser.exe",
		"selftest: ok - all checks passed",
	} {
		if !strings.Contains(env.outText(), want) {
			t.Errorf("output missing %q:\n%s", want, env.outText())
		}
	}
	if strings.Contains(env.outText(), "T9 verdict: FAIL") {
		t.Fatalf("passing selftest must not print a FAIL verdict:\n%s", env.outText())
	}
	if _, err := os.Stat(gpu); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale prune must delete Data\\GPUCache: %v", err)
	}
	if _, err := os.Stat(filepath.Join(p.root, "state.json")); err != nil {
		t.Fatalf("prune must stamp state.json: %v", err)
	}
	if env.execExe != "" {
		t.Fatal("--dry-run must never spawn browser.exe")
	}
}

func TestSelftestReportsFallbackFlagsWhenVersionDllMissing(t *testing.T) {
	p := newTestPkg(t, false)
	p.staleState(t, 30*24*time.Hour)
	env := newTestEnv(t, p)

	code := env.run("--selftest", "--dry-run", "--lang", "en",
		"--findings", writeFindings(t, sampleIgnored), "--debloater", writeDebloater(t))

	if code != 0 {
		t.Fatalf("exit = %d, output:\n%s", code, env.outText())
	}
	joined := env.outText()
	if !strings.Contains(joined, "version.dll missing - fallback flags: --user-data-dir") {
		t.Fatalf("fallback flags not reported:\n%s", joined)
	}
	if !strings.Contains(joined, filepath.Join(p.root, "Data")) {
		t.Fatalf("fallback must point at the portable Data dir:\n%s", joined)
	}
}

func TestSelftestHonoredModeAppliesAndRemovesPolicy(t *testing.T) {
	p := newTestPkg(t, true)
	p.staleState(t, 30*24*time.Hour)
	env := newTestEnv(t, p)

	code := env.run("--selftest", "--dry-run", "--lang", "en",
		"--findings", writeFindings(t, "T1 verdict: HONORED - both keys listed"),
		"--debloater", writeDebloater(t))

	if code != 0 {
		t.Fatalf("exit = %d, output:\n%s", code, env.outText())
	}
	for _, want := range []string{
		"mode: hkcu",
		"policy: applied 2 values",
		"readback ok - 2 values present during run",
		"cleanup - deleted=2",
	} {
		if !strings.Contains(env.outText(), want) {
			t.Errorf("output missing %q:\n%s", want, env.outText())
		}
	}
	if len(env.view.values) != 0 {
		t.Fatalf("HKCU leaks after exit: %v", env.view.values)
	}
	if !env.view.keyRemoved {
		t.Fatal("the emptied policy key must be removed on exit")
	}
}

// The package ships debloater.reg beside browser.exe (Yandex\debloater.reg),
// so that is the default source when --debloater is not given.
func TestDefaultDebloaterIsTheShippedFileBesideBrowserExe(t *testing.T) {
	p := newTestPkg(t, true)
	p.staleState(t, 30*24*time.Hour)
	writeDebloaterIn(t, p.appDir)
	env := newTestEnv(t, p)

	code := env.run("--selftest", "--dry-run", "--lang", "en",
		"--findings", writeFindings(t, "T1 verdict: HONORED - both keys listed"))

	if code != 0 {
		t.Fatalf("exit = %d, output:\n%s", code, env.outText())
	}
	if !strings.Contains(env.outText(), "policy: applied 2 values") {
		t.Fatalf("the shipped debloater.reg was not picked up from the app dir:\n%s", env.outText())
	}
}

func TestSelftestSkipsPruneWhileBrowserRunning(t *testing.T) {
	p := newTestPkg(t, true)
	p.staleState(t, 30*24*time.Hour)
	gpu := p.mkdir(t, "GPUCache")
	env := newTestEnv(t, p)
	env.running = true

	code := env.run("--selftest", "--dry-run", "--lang", "en",
		"--findings", writeFindings(t, sampleIgnored), "--debloater", writeDebloater(t))

	if code != 0 {
		t.Fatalf("exit = %d, output:\n%s", code, env.outText())
	}
	if !strings.Contains(env.outText(), "prune: browser running - skipped") {
		t.Fatalf("skip must be reported:\n%s", env.outText())
	}
	if _, err := os.Stat(gpu); err != nil {
		t.Fatalf("a running browser must abort the prune: %v", err)
	}
}

func TestSelftestFailsWhenFindingsDocMissing(t *testing.T) {
	p := newTestPkg(t, true)
	env := newTestEnv(t, p)
	missing := filepath.Join(t.TempDir(), "nope.md")

	code := env.run("--selftest", "--dry-run", "--lang", "en", "--findings", missing)

	if code == 0 {
		t.Fatal("a missing findings doc means Task 1 is incomplete - must fail")
	}
	if !strings.Contains(env.outText(), "Task 1 incomplete") {
		t.Fatalf("failure must name Task 1:\n%s", env.outText())
	}
}

func TestSelftestHoldReceivesForwardedURL(t *testing.T) {
	p := newTestPkg(t, true)
	p.staleState(t, 30*24*time.Hour)
	env := newTestEnv(t, p)
	env.lock.deliver = "https://example.test/late"

	code := env.run("--selftest", "--dry-run", "--lang", "en", "--hold-ms", "1500",
		"--findings", writeFindings(t, sampleIgnored), "--debloater", writeDebloater(t))

	if code != 0 {
		t.Fatalf("exit = %d, output:\n%s", code, env.outText())
	}
	if !strings.Contains(env.outText(), "hold received url https://example.test/late") {
		t.Fatalf("hold window must report the forwarded url:\n%s", env.outText())
	}
	if !env.lock.stopped {
		t.Fatal("the forward channel must be stopped before exit")
	}
	if env.lock.listenCalls != 1 {
		t.Fatalf("listen calls = %d want 1", env.lock.listenCalls)
	}
}

// -------------------------------------------------------- second instance --

func TestSecondInstanceForwardsURLAndExitsZero(t *testing.T) {
	p := newTestPkg(t, true)
	env := newTestEnv(t, p)
	env.lock.acquired = false
	env.lock.forwardOK = true

	code := env.run("https://example.test/from-second")

	if code != 0 {
		t.Fatalf("second invocation must exit 0, got %d", code)
	}
	if len(env.lock.forwarded) != 1 || env.lock.forwarded[0] != "https://example.test/from-second" {
		t.Fatalf("forwarded = %v", env.lock.forwarded)
	}
	if !strings.Contains(env.outText(), "forward: url delivered") {
		t.Fatalf("delivery must be logged:\n%s", env.outText())
	}
	if env.execExe != "" {
		t.Fatal("the second instance must not spawn a browser")
	}
}

func TestSecondInstanceWithoutTargetLogsAndExitsZero(t *testing.T) {
	p := newTestPkg(t, true)
	env := newTestEnv(t, p)
	env.lock.acquired = false
	env.lock.forwardOK = false
	env.lock.forwardErr = errors.New("no listener")

	code := env.run("https://example.test/nobody-home")

	if code != 0 {
		t.Fatalf("no window handle must still exit 0, got %d", code)
	}
	if !strings.Contains(env.outText(), "no forwarding target (no window handle)") {
		t.Fatalf("fallback must be logged:\n%s", env.outText())
	}
}

func TestSecondInstanceWithoutURLExitsZero(t *testing.T) {
	p := newTestPkg(t, true)
	env := newTestEnv(t, p)
	env.lock.acquired = false

	code := env.run()

	if code != 0 {
		t.Fatalf("exit = %d want 0", code)
	}
	if !strings.Contains(env.outText(), "no url in argv") {
		t.Fatalf("output:\n%s", env.outText())
	}
	if len(env.lock.forwarded) != 0 {
		t.Fatalf("nothing to forward, got %v", env.lock.forwarded)
	}
}

// ------------------------------------------------------------ normal mode --

func TestNormalModeWaitsAndPropagatesExitCode(t *testing.T) {
	p := newTestPkg(t, false)
	p.staleState(t, 30*24*time.Hour)
	env := newTestEnv(t, p)
	env.execRet = 42

	code := env.run("--lang", "en",
		"--findings", writeFindings(t, "T1 verdict: HONORED - both keys listed"),
		"--debloater", writeDebloater(t))

	if code != 42 {
		t.Fatalf("launcher must propagate the browser exit code, got %d", code)
	}
	if env.execExe != p.exe {
		t.Fatalf("exec = %q want %q", env.execExe, p.exe)
	}
	if len(env.view.values) != 0 {
		t.Fatalf("policy must be removed on graceful exit, still holds %v", env.view.values)
	}
	if !strings.Contains(env.outText(), "browser exited with code 42") {
		t.Fatalf("output:\n%s", env.outText())
	}
}

// --------------------------------------------------------------- settings --

func TestSettingsPrintsConfigInBothLanguages(t *testing.T) {
	p := newTestPkg(t, true)
	findings := writeFindings(t, sampleIgnored)

	env := newTestEnv(t, p)
	if code := env.run("--settings", "--lang", "en", "--findings", findings, "--prune-days", "5"); code != 0 {
		t.Fatalf("--settings exit = %d", code)
	}
	en := env.outText()
	for _, want := range []string{"language: en", "hkcu-mode", p.appDir, "prune-days: 5"} {
		if !strings.Contains(en, want) {
			t.Errorf("EN settings missing %q:\n%s", want, en)
		}
	}

	env2 := newTestEnv(t, p)
	if code := env2.run("--settings", "--lang", "ru", "--findings", findings); code != 0 {
		t.Fatalf("--settings exit = %d", code)
	}
	ru := env2.outText()
	if !strings.Contains(ru, "язык: ru") || !strings.Contains(ru, "настройки:") {
		t.Fatalf("RU settings not localised:\n%s", ru)
	}
}

func TestSettingsNeverTouchesTheMutexOrRegistry(t *testing.T) {
	p := newTestPkg(t, true)
	env := newTestEnv(t, p)
	if code := env.run("--settings", "--lang", "en"); code != 0 {
		t.Fatalf("exit = %d", code)
	}
	if env.lock.acquireCalls != 0 {
		t.Fatal("--settings must not acquire the single-instance mutex")
	}
	if len(env.view.values) != 0 {
		t.Fatal("--settings must not write HKCU")
	}
}

func TestInvalidLanguageFallsBackToEnglish(t *testing.T) {
	p := newTestPkg(t, true)
	env := newTestEnv(t, p)
	if code := env.run("--settings", "--lang", "de"); code != 0 {
		t.Fatalf("exit = %d", code)
	}
	if !strings.Contains(env.outText(), "language: en") {
		t.Fatalf("unsupported --lang must fall back to EN:\n%s", env.outText())
	}
}
