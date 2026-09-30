package main

import (
	"errors"
	"strings"
	"testing"
)

// T1->T9 delivery mechanism (plan §2): the findings doc is the named single
// source. HONORED -> HKCU mode runs; IGNORED/FAIL/missing -> skip with the
// exact reason logged; a missing doc means Task 1 is incomplete and we stop.

const sampleIgnored = "T1 verdict: IGNORED - YandexAliceMsgDisable, Telemetry absent from chrome://policy after HKCU reg add (via=uia bytes=10269)"

func TestResolveModeHonoredEnablesHkcu(t *testing.T) {
	d, err := ResolveMode("intro\nT1 verdict: HONORED - both keys listed\ntrailing", true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !d.Active {
		t.Fatal("HONORED must enable HKCU mode")
	}
	if d.Verdict != "HONORED" {
		t.Fatalf("Verdict = %q want HONORED", d.Verdict)
	}
}

func TestResolveModeIgnoredSkipsWithExactReason(t *testing.T) {
	d, err := ResolveMode(sampleIgnored, true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if d.Active {
		t.Fatal("IGNORED must skip HKCU mode")
	}
	if d.Verdict != "IGNORED" {
		t.Fatalf("Verdict = %q want IGNORED", d.Verdict)
	}
	if !strings.Contains(d.Reason, sampleIgnored) {
		t.Fatalf("reason must carry the exact verdict line, got %q", d.Reason)
	}
}

func TestResolveModeFailSkips(t *testing.T) {
	d, err := ResolveMode("T1 verdict: FAIL - probe crashed", true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if d.Active {
		t.Fatal("FAIL must skip HKCU mode")
	}
	if d.Verdict != "FAIL" {
		t.Fatalf("Verdict = %q want FAIL", d.Verdict)
	}
}

func TestResolveModeMissingFindingsIsTask1Incomplete(t *testing.T) {
	_, err := ResolveMode("", false)
	if !errors.Is(err, errFindingsMissing) {
		t.Fatalf("want errFindingsMissing, got %v", err)
	}
	if !strings.Contains(err.Error(), "Task 1") {
		t.Fatalf("error must name Task 1 as incomplete, got %q", err)
	}
}

func TestResolveModeMissingT1LineIsTask1Incomplete(t *testing.T) {
	_, err := ResolveMode("# findings doc\n\nPENDING", true)
	if !errors.Is(err, errT1Missing) {
		t.Fatalf("want errT1Missing, got %v", err)
	}
	if !strings.Contains(err.Error(), "Task 1") {
		t.Fatalf("error must name Task 1 as incomplete, got %q", err)
	}
}

func TestResolveModeUsesFirstT1LineOnly(t *testing.T) {
	// The doc also contains section prose mentioning T1; only the verdict line
	// (line-initial "T1 verdict:") counts.
	text := "## T1 section prose mentioning T1 verdict in past tense\n" + sampleIgnored + "\nT1 verdict: HONORED later rerun\n"
	d, err := ResolveMode(text, true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if d.Verdict != "IGNORED" {
		t.Fatalf("must bind to the first verdict line, got %q", d.Verdict)
	}
}
