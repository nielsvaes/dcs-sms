package main

import (
	"bytes"
	"strings"
	"testing"
)

// TestMeUnitGetSelectorValidation exercises the four-way XOR on
// --name/--id/--group-name/--group-id. The verb requires exactly one;
// anything else exits 2 with a usage message before reaching the ME.
func TestMeUnitGetSelectorValidation(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want int
	}{
		{"no selector", []string{}, 2},
		{"name + id", []string{"--name", "x", "--id", "1"}, 2},
		{"name + group-name", []string{"--name", "x", "--group-name", "g"}, 2},
		{"id + group-id", []string{"--id", "1", "--group-id", "2"}, 2},
		{"group-name + group-id", []string{"--group-name", "g", "--group-id", "2"}, 2},
		{"all four", []string{"--name", "x", "--id", "1", "--group-name", "g", "--group-id", "2"}, 2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			got := meUnitGetCmd(tc.args, &stdout, &stderr)
			if got != tc.want {
				t.Errorf("exit code = %d, want %d (stderr: %q)", got, tc.want, stderr.String())
			}
			if !strings.Contains(stderr.String(), "exactly one") {
				t.Errorf("stderr missing usage hint: %q", stderr.String())
			}
		})
	}
}

// TestMeUnitGetFlagParsing confirms each new flag binds correctly.
func TestMeUnitGetFlagParsing(t *testing.T) {
	fs, opts := meUnitGetFlags()
	if err := fs.Parse([]string{"--group-name", "Gee Goodwood Beacon", "--group-id", "42"}); err != nil {
		t.Fatalf("parse failed: %v", err)
	}
	if opts.GroupName != "Gee Goodwood Beacon" {
		t.Errorf("GroupName = %q, want %q", opts.GroupName, "Gee Goodwood Beacon")
	}
	if opts.GroupID != 42 {
		t.Errorf("GroupID = %d, want 42", opts.GroupID)
	}
}
