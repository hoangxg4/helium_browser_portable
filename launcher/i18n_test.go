package main

import (
	"sort"
	"testing"
)

// The launcher is bilingual (issue #1 §8): every key the EN table carries must
// exist in the RU table with a non-empty translation, otherwise a --lang ru run
// silently falls back to English mid-sentence.

func sortedKeys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func TestKeySetsAreIdenticalAcrossLanguages(t *testing.T) {
	en := sortedKeys(messageTable[langEN])
	ru := sortedKeys(messageTable[langRU])
	if len(en) == 0 {
		t.Fatal("EN string table is empty")
	}
	if len(en) != len(ru) {
		t.Fatalf("key-set size mismatch: en=%d ru=%d\nen=%v\nru=%v", len(en), len(ru), en, ru)
	}
	for i := range en {
		if en[i] != ru[i] {
			t.Fatalf("key-set mismatch at %d: en=%q ru=%q", i, en[i], ru[i])
		}
	}
}

func TestEveryTranslationIsNonEmpty(t *testing.T) {
	for lang, table := range messageTable {
		for key, val := range table {
			if val == "" {
				t.Errorf("empty %s translation for key %q", lang, key)
			}
		}
	}
}

func TestTranslateReturnsLocalisedText(t *testing.T) {
	got := translate(langRU, "mutex.acquired")
	if got == "" || got == translate(langEN, "mutex.acquired") {
		t.Fatalf("RU mutex.acquired not localised: %q", got)
	}
}

func TestTranslateFallsBackToEnglish(t *testing.T) {
	if got := translate("de", "mutex.acquired"); got != translate(langEN, "mutex.acquired") {
		t.Fatalf("unknown language must fall back to EN, got %q", got)
	}
	if got := translate(langRU, "no.such.key"); got != "no.such.key" {
		t.Fatalf("unknown key must return the key itself, got %q", got)
	}
}

func TestNormalizeLang(t *testing.T) {
	cases := map[string]string{
		"ru": "ru", "RU": "ru", "ru-RU": "ru", "en": "en", "en-US": "en",
	}
	for in, want := range cases {
		got, ok := normalizeLang(in)
		if !ok || got != want {
			t.Errorf("normalizeLang(%q) = %q,%v want %q,true", in, got, ok, want)
		}
	}
	if _, ok := normalizeLang("de"); ok {
		t.Error("unsupported language must be rejected, not silently accepted")
	}
	if _, ok := normalizeLang(""); ok {
		t.Error("empty language must be rejected")
	}
}
