package main

import (
	"bytes"
	"strings"
	"testing"
)

// TestMeCoordsToGeoRequiresNorthAndEast confirms the Go side catches
// "user omitted --north/--east" — neither defaults from flag (0) can be
// distinguished from a deliberate origin coord by value alone, so we use
// fs.Visit to detect actual presence. Without this, omitting --north
// silently converts (0, 0) and the user gets the theatre origin back.
func TestMeCoordsToGeoRequiresNorthAndEast(t *testing.T) {
	cases := []struct {
		name string
		args []string
	}{
		{"empty", []string{}},
		{"north only", []string{"--north", "100"}},
		{"east only", []string{"--east", "100"}},
		{"alt only", []string{"--alt", "100"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			got := meCoordsToGeoCmd(tc.args, &stdout, &stderr)
			if got != 2 {
				t.Errorf("exit code = %d, want 2 (stderr: %q)", got, stderr.String())
			}
			if !strings.Contains(stderr.String(), "--north and --east are required") {
				t.Errorf("stderr missing usage hint: %q", stderr.String())
			}
		})
	}
}

// TestMeCoordsToLocalRequiresLatAndLon mirrors the same guard on to-local.
func TestMeCoordsToLocalRequiresLatAndLon(t *testing.T) {
	cases := []struct {
		name string
		args []string
	}{
		{"empty", []string{}},
		{"lat only", []string{"--lat", "45"}},
		{"lon only", []string{"--lon", "36"}},
		{"alt only", []string{"--alt", "100"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			got := meCoordsToLocalCmd(tc.args, &stdout, &stderr)
			if got != 2 {
				t.Errorf("exit code = %d, want 2 (stderr: %q)", got, stderr.String())
			}
			if !strings.Contains(stderr.String(), "--lat and --lon are required") {
				t.Errorf("stderr missing usage hint: %q", stderr.String())
			}
		})
	}
}

// TestMeCoordsToGeoFlagBinding spot-checks that each flag binds to the
// right field — catches future copy-paste typos in the flag wiring.
func TestMeCoordsToGeoFlagBinding(t *testing.T) {
	fs, opts := meCoordsToGeoFlags()
	if err := fs.Parse([]string{"--north", "155314", "--east", "-37598.8", "--alt", "194"}); err != nil {
		t.Fatalf("parse failed: %v", err)
	}
	if opts.North != 155314 {
		t.Errorf("North = %g, want 155314", opts.North)
	}
	if opts.East != -37598.8 {
		t.Errorf("East = %g, want -37598.8", opts.East)
	}
	if opts.Alt != 194 {
		t.Errorf("Alt = %g, want 194", opts.Alt)
	}
}

func TestMeCoordsToLocalFlagBinding(t *testing.T) {
	fs, opts := meCoordsToLocalFlags()
	if err := fs.Parse([]string{"--lat", "50.891186", "--lon", "-0.754503", "--alt", "194"}); err != nil {
		t.Fatalf("parse failed: %v", err)
	}
	if opts.Lat != 50.891186 {
		t.Errorf("Lat = %g, want 50.891186", opts.Lat)
	}
	if opts.Lon != -0.754503 {
		t.Errorf("Lon = %g, want -0.754503", opts.Lon)
	}
	if opts.Alt != 194 {
		t.Errorf("Alt = %g, want 194", opts.Alt)
	}
}
