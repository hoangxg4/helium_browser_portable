package main

// app.go — the T9 launcher (issue #1 §4-§8, plan §2).
//
// One process: resolve config/language -> take the single-instance mutex ->
// decide HKCU mode from the T1 verdict -> apply the ephemeral policy -> prune
// the portable cache -> build the launch plan -> serve the forward channel ->
// spawn browser.exe (unless --selftest/--dry-run) -> remove exactly what the
// policy session wrote -> report.
//
// Contract for --selftest: every fatal error prints
// "T9 verdict: FAIL — <reason>" and exits non-zero; a mutex create error must
// never fall back to a Local\ name, because that would fake the claim.

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// defaultFindingsPath is the named single source of truth for the T1 verdict.
const defaultFindingsPath = "docs/issue1-claims-findings.md"

// Config is the CLI surface.
type Config struct {
	Selftest  bool
	DryRun    bool
	Settings  bool
	Lang      string
	AppDir    string
	Findings  string
	Debloater string
	PruneDays int
	HoldMs    int
	URL       string
}

func parseArgs(args []string) (Config, error) {
	cfg := Config{Findings: defaultFindingsPath, PruneDays: defaultPruneDays}
	fs := flag.NewFlagSet("yandex-launcher", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.BoolVar(&cfg.Selftest, "selftest", false, "run the T9 selftest and emit a verdict line")
	fs.BoolVar(&cfg.DryRun, "dry-run", false, "do everything except spawning browser.exe")
	fs.BoolVar(&cfg.Settings, "settings", false, "print the resolved configuration")
	fs.StringVar(&cfg.Lang, "lang", "", "output language: en|ru (default: OS UI language)")
	fs.StringVar(&cfg.AppDir, "app-dir", "", "package root or Yandex\\ dir (default: next to the launcher)")
	fs.StringVar(&cfg.Findings, "findings", defaultFindingsPath, "findings doc carrying the T1 verdict")
	fs.StringVar(&cfg.Debloater, "debloater", "", "debloater.reg with the shipped policy values")
	fs.IntVar(&cfg.PruneDays, "prune-days", defaultPruneDays, "age in days after which Data\\ is pruned")
	fs.IntVar(&cfg.HoldMs, "hold-ms", 0, "--selftest only: keep the forward channel open this long")
	if err := fs.Parse(args); err != nil {
		return cfg, err
	}
	rest := fs.Args()
	switch len(rest) {
	case 0:
	case 1:
		cfg.URL = rest[0]
	default:
		return cfg, fmt.Errorf("unexpected arguments after the url: %s", strings.Join(rest[1:], " "))
	}
	return cfg, nil
}

// App runs one launcher invocation.
type App struct {
	cfg       Config
	deps      Deps
	lang      string
	layout    Layout
	plan      LaunchPlan
	policy    *PolicySession
	forwarded string
}

// NewApp fills the platform defaults for whatever a caller left unset.
func NewApp(deps Deps) *App {
	if deps.Out == nil {
		deps.Out = os.Stdout
	}
	if deps.Now == nil {
		deps.Now = time.Now
	}
	if deps.Getenv == nil {
		deps.Getenv = os.Getenv
	}
	if deps.ExeDir == "" {
		if exe, err := os.Executable(); err == nil {
			deps.ExeDir = filepath.Dir(exe)
		} else {
			deps.ExeDir = "."
		}
	}
	if deps.UILanguage == nil {
		deps.UILanguage = func() uint16 { return 0 }
	}
	if deps.Lock == nil {
		deps.Lock = newPlatformLock()
	}
	if deps.OpenPolicy == nil {
		deps.OpenPolicy = openPolicyView
	}
	if deps.NewPruneFS == nil {
		deps.NewPruneFS = func(dir string) PruneFS { return NewOSPruneFS(dir) }
	}
	if deps.BrowserRunning == nil {
		deps.BrowserRunning = func() bool { return false }
	}
	if deps.Exec == nil {
		deps.Exec = func(string, []string) (int, error) {
			return -1, errors.New("no exec backend configured")
		}
	}
	return &App{deps: deps}
}

// Run is the whole launcher; code is named so the deferred HKCU sweep can
// never let a dirty policy claim a clean exit.
func (a *App) Run(args []string) (code int) {
	cfg, err := parseArgs(args)
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		fmt.Fprintf(a.deps.Out, "error: %v\n", err)
		return 2
	}
	a.cfg = cfg
	a.lang = a.resolveLang()

	if cfg.Settings {
		return a.settings()
	}
	if cfg.Selftest {
		a.printf("selftest.start", cfg.DryRun)
	}

	acquired, err := a.deps.Lock.Acquire(mutexName)
	if err != nil {
		if cfg.Selftest {
			return a.fatal(fmt.Errorf("mutex create error: %w", err))
		}
		a.printf("mutex.error", err)
		return 1
	}
	if !acquired {
		return a.runSecondInstance()
	}
	a.printf("mutex.acquired")
	defer a.deps.Lock.Close()

	// Last line of defence: no HKCU value this run created may outlive it.
	defer func() {
		if a.policy == nil {
			return
		}
		rep, cErr := a.policy.Cleanup()
		a.policy = nil
		if cErr != nil {
			a.printf("policy.cleanup.broke", cErr)
			if code == 0 {
				code = 1
			}
			return
		}
		a.printf("policy.restored", rep.Deleted, rep.Restored, rep.Untouched)
	}()

	hint := cfg.AppDir
	if hint == "" {
		hint = a.deps.ExeDir
	}
	layout, err := ResolveLayout(hint, pathExists)
	if err != nil {
		return a.fatal(err)
	}
	a.layout = layout

	findingsText, ferr := os.ReadFile(cfg.Findings)
	decision, merr := ResolveMode(string(findingsText), ferr == nil)
	if merr != nil {
		if errors.Is(merr, errFindingsMissing) {
			return a.fatalMsg(format(a.lang, "err.findings.missing", cfg.Findings))
		}
		if errors.Is(merr, errT1Missing) {
			return a.fatalMsg(format(a.lang, "err.findings.noT1", cfg.Findings))
		}
		return a.fatal(merr)
	}
	if decision.Active {
		a.printf("mode.active", decision.Reason)
	} else {
		a.printf("mode.skip", decision.Reason)
	}

	if err := a.applyPolicy(decision); err != nil {
		return a.fatal(err)
	}
	if err := a.pruneCache(); err != nil {
		return a.fatal(err)
	}

	a.plan = BuildLaunchPlan(layout, cfg.URL, pathExists)
	if a.plan.Fallback {
		a.printf("launch.fallback", strings.Join(a.plan.Args, " "))
	} else {
		a.printf("launch.dll")
	}
	cmdline := layout.BrowserExe
	if len(a.plan.Args) > 0 {
		cmdline += " " + strings.Join(a.plan.Args, " ")
	}
	a.printf("launch.cmd", cmdline)

	// The forward channel serves only after the plan is known, so a URL that
	// arrives mid-handoff always has somewhere to go.
	stop, lerr := a.deps.Lock.Listen(mutexName, a.onForward)
	if lerr != nil {
		a.printf("forward.listen.broke", lerr)
	} else if stop != nil {
		defer func() { _ = stop() }()
	}

	if cfg.Selftest || cfg.DryRun {
		// never spawn browser.exe
	} else {
		c, execErr := a.deps.Exec(layout.BrowserExe, a.plan.Args)
		if execErr != nil {
			return a.fatal(fmt.Errorf("launch: %w", execErr))
		}
		a.printf("launch.wait", c)
		code = c
	}

	if cfg.Selftest && cfg.HoldMs > 0 {
		a.printf("selftest.hold", cfg.HoldMs)
		time.Sleep(time.Duration(cfg.HoldMs) * time.Millisecond)
		if a.forwarded != "" {
			a.printf("selftest.hold.got", a.forwarded)
		} else {
			a.printf("selftest.hold.none")
		}
	}

	if err := a.endPolicy(); err != nil {
		return a.fatal(err)
	}
	if cfg.Selftest {
		a.printf("selftest.done")
	}
	return code
}

// applyPolicy writes the debloater.reg value set into HKCU, but only in the
// HONORED mode, and records the before-state for cleanup.
func (a *App) applyPolicy(d ModeDecision) error {
	if !d.Active {
		return nil
	}
	view, err := a.deps.OpenPolicy()
	if err != nil {
		return errors.New(format(a.lang, "policy.open.broke", err))
	}

	// The package ships debloater.reg beside browser.exe (Yandex\debloater.reg),
	// next to the other protected files update.bat manages.
	regPath := a.cfg.Debloater
	if regPath == "" {
		regPath = filepath.Join(a.layout.AppDir, "debloater.reg")
	}
	raw, err := os.ReadFile(regPath)
	if err != nil {
		return fmt.Errorf("read %s: %w", regPath, err)
	}
	entries, err := ParseDebloaterReg(string(raw))
	if err != nil {
		return err
	}
	sess, err := BeginPolicy(view, entries)
	if err != nil {
		return err
	}
	a.policy = sess
	a.printf("policy.applied", len(entries))

	if _, err := sess.Verify(); err != nil {
		a.printf("policy.readback.broke", err)
		return err
	}
	a.printf("policy.verified", len(entries))
	return nil
}

// endPolicy releases the HKCU session on the happy path (the deferred sweep
// covers every fatal path before it).
func (a *App) endPolicy() error {
	if a.policy == nil {
		return nil
	}
	rep, err := a.policy.Cleanup()
	a.policy = nil
	if err != nil {
		a.printf("policy.cleanup.broke", err)
		return err
	}
	a.printf("policy.restored", rep.Deleted, rep.Restored, rep.Untouched)
	return nil
}

// pruneCache is T7: delete the volatile dirs only when state.json is old
// enough and no browser.exe is holding the profile.
func (a *App) pruneCache() error {
	statePath := filepath.Join(a.layout.Root, "state.json")
	maxAge := time.Duration(a.cfg.PruneDays) * 24 * time.Hour

	if a.deps.BrowserRunning() {
		a.printf("prune.busy")
		return nil
	}
	age, present, err := StateAge(statePath, a.deps.Now())
	if err != nil {
		return err
	}
	decision := EvaluatePrune(present, age, maxAge)
	if !decision.Stale {
		a.printf("prune.fresh", decision.Reason)
		return nil
	}
	a.printf("prune.stale", decision.Reason)

	removed, err := RunPrune(a.deps.NewPruneFS(filepath.Join(a.layout.Root, "Data")))
	if err != nil {
		return err
	}
	if err := WriteState(statePath, a.deps.Now()); err != nil {
		return err
	}
	a.printf("prune.executed", len(removed), strings.Join(removed, ", "))
	a.printf("prune.state", statePath)
	return nil
}

// runSecondInstance owns the non-primary path: hand the URL over, or say so
// and exit 0 — never a hard failure, never a second browser.
func (a *App) runSecondInstance() int {
	a.printf("mutex.busy")
	if a.cfg.URL == "" {
		a.printf("second.nothing")
		return 0
	}
	delivered, err := a.deps.Lock.Forward(mutexName, a.cfg.URL)
	if err == nil && delivered {
		a.printf("forward.sent", a.cfg.URL)
		return 0
	}
	if err == nil {
		err = errors.New("no window handle")
	}
	a.printf("forward.none", err)
	return 0
}

// onForward handles a URL the primary received while it was running. In a
// --selftest/--dry-run it is only recorded; otherwise browser.exe is relaunched
// with the URL and Chromium's own singleton forwards it into the live window.
func (a *App) onForward(url string) {
	a.forwarded = url
	if a.cfg.Selftest || a.cfg.DryRun || a.layout.BrowserExe == "" {
		return
	}
	args := append(append([]string{}, a.plan.Args...), url)
	exe, exec := a.layout.BrowserExe, a.deps.Exec
	go func() {
		if _, err := exec(exe, args); err != nil {
			fmt.Fprintf(a.deps.Out, "%s\n", format(a.lang, "forward.handoff.broke", err))
		}
	}()
}

func (a *App) settings() int {
	a.printf("settings.title")
	a.printf("settings.lang", a.lang)

	mode := "unavailable"
	if text, err := os.ReadFile(a.cfg.Findings); err == nil {
		if d, derr := ResolveMode(string(text), true); derr == nil {
			if d.Active {
				mode = "hkcu"
			} else {
				mode = "skip - " + d.Reason
			}
		}
	}
	a.printf("settings.mode", mode)

	appDir, root := a.cfg.AppDir, a.cfg.AppDir
	if appDir == "" {
		appDir = a.deps.ExeDir
		root = a.deps.ExeDir
	}
	if l, err := ResolveLayout(appDir, pathExists); err == nil {
		appDir, root = l.AppDir, l.Root
	}
	a.printf("settings.app", appDir)
	a.printf("settings.root", root)
	a.printf("settings.prune", a.cfg.PruneDays)
	a.printf("settings.dryrun", a.cfg.DryRun)
	return 0
}

func (a *App) fatal(err error) int { return a.fatalMsg(err.Error()) }

func (a *App) fatalMsg(msg string) int {
	if a.cfg.Selftest {
		fmt.Fprintf(a.deps.Out, "T9 verdict: FAIL — %s\n", msg)
	} else {
		fmt.Fprintf(a.deps.Out, "error: %s\n", msg)
	}
	return 1
}

func (a *App) printf(key string, args ...any) {
	fmt.Fprintln(a.deps.Out, format(a.lang, key, args...))
}

// resolveLang: explicit --lang, then the OS UI language, then the POSIX locale.
func (a *App) resolveLang() string {
	if a.cfg.Lang != "" {
		if l, ok := normalizeLang(a.cfg.Lang); ok {
			return l
		}
	}
	if a.deps.UILanguage != nil {
		if l, ok := normalizeLang(langFromLCID(a.deps.UILanguage())); ok {
			return l
		}
	}
	if a.deps.Getenv != nil {
		for _, k := range []string{"LC_ALL", "LC_MESSAGES", "LANG"} {
			if l, ok := normalizeLang(a.deps.Getenv(k)); ok {
				return l
			}
		}
	}
	return langEN
}

// langFromLCID maps the primary language id of a Windows LCID onto a tag.
func langFromLCID(lcid uint16) string {
	switch lcid & 0x3ff {
	case 0x09:
		return langEN
	case 0x19:
		return langRU
	}
	return ""
}

func pathExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}
