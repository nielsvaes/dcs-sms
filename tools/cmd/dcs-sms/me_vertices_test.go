package main

import (
	"strings"
	"testing"
)

func TestParseVerticesToLua_Pair(t *testing.T) {
	got, err := parseVerticesToLua("100.5,200;300,400.25")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := "{ { north = 100.5, east = 200 }, { north = 300, east = 400.25 } }"
	if got != want {
		t.Errorf("got %q\nwant %q", got, want)
	}
}

// A vertex carrying locale comma-decimals (e.g. "230006,5,400000,5" for an
// intended "230006.5,400000.5") splits into four fields. We can't reconstruct
// the intent, but we must reject it with a hint rather than draw something
// wrong. Regression for GH#73, request 7.
func TestParseVerticesToLua_LocaleCommaRejected(t *testing.T) {
	_, err := parseVerticesToLua("230006,5,400000,5;500000,5,600000,5")
	if err == nil {
		t.Fatal("expected an error for locale comma-decimals, got nil")
	}
	if !strings.Contains(err.Error(), "decimals") {
		t.Errorf("error should hint at the decimal/locale cause, got: %v", err)
	}
}

func TestParseVerticesToLua_Empty(t *testing.T) {
	if _, err := parseVerticesToLua("   "); err == nil {
		t.Error("expected an error for empty input")
	}
}

func TestLocaleCommaHint_EvenFieldsMentionsSeparator(t *testing.T) {
	// 4 fields (two comma-decimal pairs) → the classic locale symptom.
	if h := localeCommaHint(4); !strings.Contains(h, "separator") {
		t.Errorf("even-field hint should explain the comma is a separator, got: %q", h)
	}
	// 1 field (no comma at all) → generic guidance, not the locale story.
	if h := localeCommaHint(1); strings.Contains(h, "230006") {
		t.Errorf("single-field hint should be generic, got: %q", h)
	}
}
