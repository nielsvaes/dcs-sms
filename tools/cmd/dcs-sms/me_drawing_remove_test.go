package main

import (
	"bytes"
	"strings"
	"testing"
)

// TestMeDrawingRemoveRequiresSelector verifies the CLI rejects an empty
// call (no --name, --name-prefix, or --layer) at exit code 2.
func TestMeDrawingRemoveRequiresSelector(t *testing.T) {
	var stdout, stderr bytes.Buffer
	exit := meDrawingRemoveCmd(nil, &stdout, &stderr)
	if exit != 2 {
		t.Fatalf("exit = %d, want 2 (no selector); stderr=%q", exit, stderr.String())
	}
	if !strings.Contains(stderr.String(), "--name") {
		t.Errorf("stderr should mention selectors, got %q", stderr.String())
	}
}

// TestMeDrawingRemoveRejectsLayerWithoutAll verifies a bare --layer call
// without --all is rejected — the safety guard against accidentally wiping
// a whole layer.
func TestMeDrawingRemoveRejectsLayerWithoutAll(t *testing.T) {
	var stdout, stderr bytes.Buffer
	exit := meDrawingRemoveCmd([]string{"--layer", "Blue"}, &stdout, &stderr)
	if exit != 2 {
		t.Fatalf("exit = %d, want 2 (layer needs --all); stderr=%q", exit, stderr.String())
	}
	if !strings.Contains(stderr.String(), "--all") {
		t.Errorf("stderr should mention --all, got %q", stderr.String())
	}
}

// TestMeDrawingRemoveRejectsNameWithPrefix verifies --name and --name-prefix
// are mutually exclusive.
func TestMeDrawingRemoveRejectsNameWithPrefix(t *testing.T) {
	var stdout, stderr bytes.Buffer
	exit := meDrawingRemoveCmd([]string{"--name", "X", "--name-prefix", "Y"}, &stdout, &stderr)
	if exit != 2 {
		t.Fatalf("exit = %d, want 2 (mutex); stderr=%q", exit, stderr.String())
	}
	if !strings.Contains(stderr.String(), "exclusive") {
		t.Errorf("stderr should mention exclusive, got %q", stderr.String())
	}
}
