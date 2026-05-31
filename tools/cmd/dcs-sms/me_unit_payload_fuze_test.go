package main

import (
	"strings"
	"testing"
)

func TestMeUnitPayloadSetFuzeCmd_FailModes(t *testing.T) {
	cases := []setterCase{
		{"no-id", []string{"--pylon", "1", "--set", "x=1"}, "exactly one of"},
		{"both-id", []string{"--name", "u", "--id", "5", "--pylon", "1", "--set", "x=1"}, "exactly one of"},
		{"no-pylon", []string{"--name", "u", "--set", "x=1"}, "--pylon"},
		{"no-set", []string{"--name", "u", "--pylon", "1"}, "--set"},
		{"bad-set", []string{"--name", "u", "--pylon", "1", "--set", "novalue"}, "key=value"},
		{"empty-key", []string{"--name", "u", "--pylon", "1", "--set", "=1"}, "empty key"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { runFailCase(t, meUnitPayloadSetFuzeCmd, c) })
	}
}

func TestMeUnitPayloadListSettingsCmd_FailModes(t *testing.T) {
	cases := []setterCase{
		{"no-id", []string{"--pylon", "1"}, "exactly one of"},
		{"no-pylon-or-weapon", []string{"--name", "u"}, "--pylon"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { runFailCase(t, meUnitPayloadListSettingsCmd, c) })
	}
}

func TestParseSetPairs(t *testing.T) {
	pairs, err := parseSetPairs([]string{
		"NFP_fuze_type_nose=1",
		"Function Delay=11",
		"NFP_PRESID=WWII_B_B_GPMkIV",
		"dispname=a=b", // value with '=' survives
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(pairs) != 4 {
		t.Fatalf("got %d pairs, want 4", len(pairs))
	}
	// Order is preserved (settings can gate each other via VisibilityCondition).
	if pairs[0].Key != "NFP_fuze_type_nose" || pairs[0].Value != "1" {
		t.Errorf("pair[0] = %+v", pairs[0])
	}
	if pairs[1].Key != "Function Delay" || pairs[1].Value != "11" {
		t.Errorf("pair[1] = %+v", pairs[1])
	}
	if pairs[3].Key != "dispname" || pairs[3].Value != "a=b" {
		t.Errorf("pair[3] = %+v (value after first = should survive)", pairs[3])
	}
}

func TestBuildSetsExpr(t *testing.T) {
	if got := buildSetsExpr(nil); got != "{}" {
		t.Errorf("empty: got %q, want {}", got)
	}
	expr := buildSetsExpr([]struct{ Key, Value string }{
		{"NFP_fuze_type_nose", "1"},
		{"Function Delay", "11"},
	})
	for _, want := range []string{
		`key = "NFP_fuze_type_nose"`, `value = "1"`,
		`key = "Function Delay"`, `value = "11"`,
	} {
		if !strings.Contains(expr, want) {
			t.Errorf("expr %q missing %q", expr, want)
		}
	}
}
