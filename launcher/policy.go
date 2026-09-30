package main

// policy.go — ephemeral HKCU policy lifecycle (issue #1 §5).
//
// debloater.reg is the single source of truth for the shipped value set; the
// launcher replays that set into HKCU\Software\Policies\YandexBrowser only
// when T1 proved HKCU is honored, and on exit removes exactly what it created
// while restoring any pre-existing user value (recorded before the write).

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// policyPath is the HKCU key the launcher owns for the duration of a run.
const policyPath = `Software\Policies\YandexBrowser`

// policySection is debloater.reg's own section (HKLM): the names and dword
// payloads are identical, only the hive differs.
const policySection = `hkey_local_machine\software\policies\yandexbrowser`

// PolicyEntry is one REG_DWORD value.
type PolicyEntry struct {
	Name string
	Data uint32
}

// RegistryView is the registry seam (platform_windows.go on Windows, an
// in-memory fake in tests).
type RegistryView interface {
	Get(name string) (uint32, bool, error)
	Set(name string, data uint32) error
	Delete(name string) error
	ValueNames() ([]string, error)
	// Close releases the key; when deleteIfEmpty is set and no values are
	// left, the now-empty policy key itself is removed.
	Close(deleteIfEmpty bool) error
}

var (
	policySectionRe = regexp.MustCompile(`(?i)^\s*\[([^\]]+)\]\s*$`)
	policyValueRe   = regexp.MustCompile(`(?i)^\s*"([^"]+)"\s*=\s*dword:([0-9a-fA-F]{1,8})\s*$`)
)

// ParseDebloaterReg reads the shipped .reg file and returns its policy values.
func ParseDebloaterReg(text string) ([]PolicyEntry, error) {
	var (
		entries   []PolicyEntry
		inSection bool
		seen      bool
	)
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(strings.TrimSuffix(raw, "\r"))
		if m := policySectionRe.FindStringSubmatch(line); m != nil {
			inSection = strings.EqualFold(strings.TrimSpace(m[1]), policySection)
			if inSection {
				seen = true
			}
			continue
		}
		if !inSection || line == "" || strings.HasPrefix(line, ";") {
			continue
		}
		m := policyValueRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		v, err := strconv.ParseUint(m[2], 16, 32)
		if err != nil {
			return nil, fmt.Errorf("debloater.reg: bad dword for %q: %w", m[1], err)
		}
		entries = append(entries, PolicyEntry{Name: m[1], Data: uint32(v)})
	}
	if !seen {
		return nil, fmt.Errorf("debloater.reg has no [%s] section", policySection)
	}
	if len(entries) == 0 {
		return nil, fmt.Errorf("debloater.reg policy section carries no dword values")
	}
	return entries, nil
}

// PolicyReport records what cleanup did, for the log line.
type PolicyReport struct {
	Deleted    int
	Restored   int
	Untouched  int
	KeyRemoved bool
}

// PolicySession is one apply/cleanup pair.
type PolicySession struct {
	view      RegistryView
	desired   []PolicyEntry
	created   []string
	restored  map[string]uint32
	untouched []string
}

// BeginPolicy records the before-state, then writes every desired value.
// A mid-apply failure rolls back the values already written: a partial apply
// must never outlive the error that interrupted it.
func BeginPolicy(view RegistryView, desired []PolicyEntry) (*PolicySession, error) {
	s := &PolicySession{view: view, desired: desired, restored: map[string]uint32{}}
	for _, e := range desired {
		cur, present, err := view.Get(e.Name)
		if err != nil {
			return nil, fmt.Errorf("policy read %s: %w", e.Name, err)
		}
		switch {
		case !present:
			s.created = append(s.created, e.Name)
		case cur != e.Data:
			s.restored[e.Name] = cur
		default:
			s.untouched = append(s.untouched, e.Name)
		}
	}

	var written []PolicyEntry
	for _, e := range desired {
		if err := view.Set(e.Name, e.Data); err != nil {
			rb := s.rollback(written)
			if rb != nil {
				return nil, errors.Join(fmt.Errorf("policy write %s: %w", e.Name, err), rb)
			}
			return nil, fmt.Errorf("policy write %s: %w", e.Name, err)
		}
		written = append(written, e)
	}
	return s, nil
}

func (s *PolicySession) rollback(written []PolicyEntry) error {
	var errs []error
	for _, e := range written {
		if _, ok := s.restored[e.Name]; ok {
			if err := s.view.Set(e.Name, s.restored[e.Name]); err != nil {
				errs = append(errs, err)
			}
			continue
		}
		if err := s.view.Delete(e.Name); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// Verify reads every desired value back: "present during the run".
func (s *PolicySession) Verify() (int, error) {
	var bad []string
	ok := 0
	for _, e := range s.desired {
		cur, present, err := s.view.Get(e.Name)
		if err != nil {
			return ok, fmt.Errorf("policy readback %s: %w", e.Name, err)
		}
		if present && cur == e.Data {
			ok++
			continue
		}
		bad = append(bad, fmt.Sprintf("%s=%d want %d (present=%v)", e.Name, cur, e.Data, present))
	}
	if len(bad) > 0 {
		return ok, fmt.Errorf("readback mismatch: %s", strings.Join(bad, "; "))
	}
	return ok, nil
}

// Cleanup removes what was created, restores what was overwritten, leaves
// everything else alone, and drops the key when it ends up empty.
func (s *PolicySession) Cleanup() (PolicyReport, error) {
	var errs []error
	rep := PolicyReport{}

	for _, name := range s.created {
		if err := s.view.Delete(name); err != nil {
			errs = append(errs, fmt.Errorf("policy delete %s: %w", name, err))
			continue
		}
		rep.Deleted++
	}
	for name, val := range s.restored {
		if err := s.view.Set(name, val); err != nil {
			errs = append(errs, fmt.Errorf("policy restore %s: %w", name, err))
			continue
		}
		rep.Restored++
	}
	rep.Untouched = len(s.untouched)

	names, err := s.view.ValueNames()
	if err != nil {
		errs = append(errs, fmt.Errorf("policy enumerate: %w", err))
		if cerr := s.view.Close(false); cerr != nil {
			errs = append(errs, cerr)
		}
		return rep, errors.Join(errs...)
	}

	empty := len(names) == 0
	if cerr := s.view.Close(empty); cerr != nil {
		errs = append(errs, cerr)
	} else {
		rep.KeyRemoved = empty
	}
	return rep, errors.Join(errs...)
}
