package main

// mode.go — T1 -> T9 delivery mechanism (plan §2).
//
// docs/issue1-claims-findings.md is the named single source of truth: grep it
// for the T1 verdict line. HONORED runs HKCU mode; IGNORED/FAIL (or a missing
// doc/line, i.e. Task 1 incomplete) skip it with that exact reason logged.

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
)

var (
	errFindingsMissing = errors.New("findings doc missing")
	errT1Missing       = errors.New("T1 verdict line missing")
)

// t1VerdictRe is line-anchored: prose and the evidence table (which carries
// the line behind a backtick) never match.
var t1VerdictRe = regexp.MustCompile(`(?m)^T1 verdict:[ \t]*(\S+)(.*)`)

// ModeDecision says which policy mode runs and why.
type ModeDecision struct {
	Active  bool   // true only for T1 verdict HONORED
	Verdict string // first token of the verdict line, e.g. IGNORED
	Reason  string // the full verdict line, logged verbatim on skip
}

func ResolveMode(findingsText string, present bool) (ModeDecision, error) {
	if !present {
		return ModeDecision{}, fmt.Errorf("%w: docs/issue1-claims-findings.md not found (Task 1 incomplete)", errFindingsMissing)
	}
	m := t1VerdictRe.FindStringSubmatch(findingsText)
	if m == nil {
		return ModeDecision{}, fmt.Errorf("%w: no 'T1 verdict:' line in docs/issue1-claims-findings.md (Task 1 incomplete)", errT1Missing)
	}
	d := ModeDecision{
		Verdict: m[1],
		Reason:  strings.TrimSpace(m[0]),
	}
	d.Active = strings.EqualFold(d.Verdict, "HONORED")
	return d, nil
}
