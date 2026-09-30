package main

// policy_test.go — ephemeral HKCU policy lifecycle (issue #1 §5, plan §2).
// The 11-key set comes from debloater.reg (single source of truth) and is
// applied to HKCU only when T1=HONORED; on exit the launcher must remove
// exactly what it created and restore pre-existing user values.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fakeRegistryView struct {
	values     map[string]uint32
	keyRemoved bool
	setErr     error
	getErr     error
}

func newFakeRegistryView(vals map[string]uint32) *fakeRegistryView {
	v := map[string]uint32{}
	for k, x := range vals {
		v[k] = x
	}
	return &fakeRegistryView{values: v}
}

func (f *fakeRegistryView) Get(name string) (uint32, bool, error) {
	if f.getErr != nil {
		return 0, false, f.getErr
	}
	val, ok := f.values[name]
	return val, ok, nil
}

func (f *fakeRegistryView) Set(name string, data uint32) error {
	if f.setErr != nil {
		return f.setErr
	}
	f.values[name] = data
	return nil
}

func (f *fakeRegistryView) Delete(name string) error {
	delete(f.values, name)
	return nil
}

func (f *fakeRegistryView) ValueNames() ([]string, error) {
	out := make([]string, 0, len(f.values))
	for k := range f.values {
		out = append(out, k)
	}
	return out, nil
}

func (f *fakeRegistryView) Close(deleteIfEmpty bool) error {
	if deleteIfEmpty && len(f.values) == 0 {
		f.keyRemoved = true
	}
	return nil
}

func testEntries() []PolicyEntry {
	return []PolicyEntry{
		{Name: "StatisticsReporting", Data: 0},
		{Name: "YandexAliceMsgDisable", Data: 1},
		{Name: "UpdateAllowed", Data: 0},
	}
}

// ----------------------------------------------------------- reg parsing --

func TestParseDebloaterRegParsesShippedElevenKeys(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "debloater.reg"))
	if err != nil {
		t.Fatalf("read debloater.reg: %v", err)
	}
	entries, err := ParseDebloaterReg(string(raw))
	if err != nil {
		t.Fatalf("ParseDebloaterReg: %v", err)
	}
	if len(entries) != 11 {
		t.Fatalf("parsed %d entries, want exactly the shipped 11: %v", len(entries), entries)
	}
	byName := map[string]uint32{}
	for _, e := range entries {
		byName[e.Name] = e.Data
	}
	if byName["YandexAutoLaunchMode"] != 2 {
		t.Fatalf("YandexAutoLaunchMode = %d want 2", byName["YandexAutoLaunchMode"])
	}
	if byName["NtpNotificationsDisable"] != 1 {
		t.Fatalf("NtpNotificationsDisable = %d want 1", byName["NtpNotificationsDisable"])
	}
	if byName["StatisticsReporting"] != 0 {
		t.Fatalf("StatisticsReporting = %d want 0", byName["StatisticsReporting"])
	}
	if _, ok := byName["SafeBrowsingProtectionLevel"]; ok {
		t.Fatal("3-don't-touch key must never be parsed out of debloater.reg")
	}
}

func TestParseDebloaterRegRejectsMissingSection(t *testing.T) {
	if _, err := ParseDebloaterReg("[HKEY_CURRENT_USER\\Software\\Other]\n\"X\"=dword:00000001\n"); err == nil {
		t.Fatal("a file without the policy section must be an error")
	}
}

func TestParseDebloaterRegRejectsSectionWithoutDword(t *testing.T) {
	if _, err := ParseDebloaterReg("[HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\YandexBrowser]\n; only a comment\n"); err == nil {
		t.Fatal("an empty policy section must be an error, not a silent no-op")
	}
}

func TestParseDebloaterRegIgnoresCommentsAndLaterSections(t *testing.T) {
	txt := "Windows Registry Editor Version 5.00\n\n" +
		"[HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\YandexBrowser]\n" +
		"; StatisticsReporting=0 comment\n" +
		"\"StatisticsReporting\"=dword:00000000\n" +
		"\"UpdateAllowed\"=dword:00000000\n\n" +
		"[HKEY_LOCAL_MACHINE\\SOFTWARE\\SomethingElse]\n" +
		"\"StatisticsReporting\"=dword:00000009\n"
	entries, err := ParseDebloaterReg(txt)
	if err != nil {
		t.Fatalf("ParseDebloaterReg: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("entries = %v want the two from the policy section only", entries)
	}
	for _, e := range entries {
		if e.Data == 9 {
			t.Fatalf("value from the unrelated section leaked in: %+v", e)
		}
	}
}

// -------------------------------------------------------- apply/cleanup --

func TestPolicySessionAppliesVerifiesAndRemovesEverythingItCreated(t *testing.T) {
	view := newFakeRegistryView(nil)
	sess, err := BeginPolicy(view, testEntries())
	if err != nil {
		t.Fatalf("BeginPolicy: %v", err)
	}
	if len(view.values) != 3 {
		t.Fatalf("values after apply = %v want 3", view.values)
	}
	n, err := sess.Verify()
	if err != nil || n != 3 {
		t.Fatalf("Verify = %d,%v want 3,nil", n, err)
	}
	rep, err := sess.Cleanup()
	if err != nil {
		t.Fatalf("Cleanup: %v", err)
	}
	if rep.Deleted != 3 || rep.Restored != 0 {
		t.Fatalf("report = %+v want 3 deleted / 0 restored", rep)
	}
	if len(view.values) != 0 {
		t.Fatalf("HKCU still holds %v after cleanup", view.values)
	}
	if !view.keyRemoved {
		t.Fatal("an emptied policy key must be removed")
	}
}

func TestPolicySessionRestoresPreExistingUserValue(t *testing.T) {
	view := newFakeRegistryView(map[string]uint32{"UpdateAllowed": 7})
	sess, err := BeginPolicy(view, testEntries())
	if err != nil {
		t.Fatalf("BeginPolicy: %v", err)
	}
	if view.values["UpdateAllowed"] != 0 {
		t.Fatalf("apply must write the desired value, got %d", view.values["UpdateAllowed"])
	}
	rep, err := sess.Cleanup()
	if err != nil {
		t.Fatalf("Cleanup: %v", err)
	}
	if rep.Restored != 1 {
		t.Fatalf("report = %+v want 1 restored", rep)
	}
	if view.values["UpdateAllowed"] != 7 {
		t.Fatalf("pre-existing user value lost: %v", view.values)
	}
	if view.keyRemoved {
		t.Fatal("key still holds the restored value and must survive")
	}
}

func TestPolicySessionLeavesMatchingPreExistingValueAlone(t *testing.T) {
	view := newFakeRegistryView(map[string]uint32{"UpdateAllowed": 0})
	sess, err := BeginPolicy(view, testEntries())
	if err != nil {
		t.Fatalf("BeginPolicy: %v", err)
	}
	rep, err := sess.Cleanup()
	if err != nil {
		t.Fatalf("Cleanup: %v", err)
	}
	if rep.Untouched != 1 {
		t.Fatalf("report = %+v want 1 untouched", rep)
	}
	if _, ok := view.values["UpdateAllowed"]; !ok {
		t.Fatal("a user value that already matched must not be deleted")
	}
	if view.keyRemoved {
		t.Fatal("key still holds the untouched value and must survive")
	}
}

func TestPolicySessionNeverTouchesForeignValues(t *testing.T) {
	view := newFakeRegistryView(map[string]uint32{"SomeUserValue": 5})
	sess, err := BeginPolicy(view, testEntries())
	if err != nil {
		t.Fatalf("BeginPolicy: %v", err)
	}
	if _, err := sess.Cleanup(); err != nil {
		t.Fatalf("Cleanup: %v", err)
	}
	if view.values["SomeUserValue"] != 5 {
		t.Fatalf("foreign value damaged: %v", view.values)
	}
	if view.keyRemoved {
		t.Fatal("key still holds a foreign value and must survive")
	}
}

func TestPolicySessionVerifyDetectsReadbackMismatch(t *testing.T) {
	view := newFakeRegistryView(nil)
	sess, err := BeginPolicy(view, testEntries())
	if err != nil {
		t.Fatalf("BeginPolicy: %v", err)
	}
	view.values["UpdateAllowed"] = 99 // someone flipped it behind our back
	if _, err := sess.Verify(); err == nil {
		t.Fatal("a flipped value must fail the readback")
	} else if !strings.Contains(err.Error(), "UpdateAllowed") {
		t.Fatalf("error must name the offending value, got %v", err)
	}
}

func TestPolicySessionApplyPropagatesSetError(t *testing.T) {
	view := newFakeRegistryView(nil)
	view.setErr = os.ErrPermission
	if _, err := BeginPolicy(view, testEntries()); err == nil {
		t.Fatal("a registry write failure must surface, never be swallowed")
	}
}
