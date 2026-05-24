package main

import (
	"bytes"
	"strings"
	"testing"
)

// TestMeDrawingCreateChevronRequiresSize confirms --size is mandatory.
func TestMeDrawingCreateChevronRequiresSize(t *testing.T) {
	var stdout, stderr bytes.Buffer
	exit := meDrawingCreateChevronCmd(
		[]string{"--north", "100", "--east", "200", "--bearing", "45"},
		&stdout, &stderr,
	)
	if exit != 2 {
		t.Fatalf("exit = %d, want 2; stderr=%q", exit, stderr.String())
	}
	if !strings.Contains(stderr.String(), "--size") {
		t.Errorf("stderr should mention --size, got %q", stderr.String())
	}
}

// TestMeDrawingCreateChevronRejectsArmAngleOutOfRange confirms the (0, 180)
// range guard on --arm-angle. Picking 0 or 180 would produce a degenerate
// (collinear) chevron — drawn as a single line, not a V.
func TestMeDrawingCreateChevronRejectsArmAngleOutOfRange(t *testing.T) {
	cases := []string{"0", "180", "-30", "200"}
	for _, val := range cases {
		var stdout, stderr bytes.Buffer
		exit := meDrawingCreateChevronCmd(
			[]string{"--north", "0", "--east", "0", "--bearing", "0", "--size", "1000", "--arm-angle", val},
			&stdout, &stderr,
		)
		if exit != 2 {
			t.Errorf("--arm-angle %s: exit = %d, want 2; stderr=%q", val, exit, stderr.String())
		}
	}
}

// TestMeDrawingCreateChevronFlagDefaults verifies the default --arm-angle.
// Default 100 gives a wide V (160° tip) suited to route tick marks.
func TestMeDrawingCreateChevronFlagDefaults(t *testing.T) {
	fs, opts := meDrawingCreateChevronFlags()
	if err := fs.Parse(nil); err != nil {
		t.Fatalf("parse failed: %v", err)
	}
	if opts.ArmAngle != 100 {
		t.Errorf("default --arm-angle = %v, want 100", opts.ArmAngle)
	}
}
