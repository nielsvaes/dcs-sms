package genunits

import (
	"strings"
	"testing"
)

// EmitInputs wraps the args EmitUnits / EmitStatics need so the tests can
// build them up declaratively.
func sampleEmitInputs() ([]ClassifiedEntry, []ClassifiedEntry) {
	units := []ClassifiedEntry{
		{Bucket: Bucket{"units", "planes", ""}, Type: "F-16C_50", Identifier: "F_16C_50", OriginLabel: ""},
		{Bucket: Bucket{"units", "armor", "tanks"}, Type: "T-72B", Identifier: "T_72B", OriginLabel: ""},
		{Bucket: Bucket{"units", "armor", "tanks"}, Type: "T-80B", Identifier: "T_80B", OriginLabel: "Cold War Asset Pack"},
		{Bucket: Bucket{"units", "armor", "tanks"}, Type: "M-1 Abrams", Identifier: "M_1_Abrams", OriginLabel: ""},
		{Bucket: Bucket{"units", "armor", "ifv"}, Type: "BMP-2", Identifier: "BMP_2", OriginLabel: ""},
		{Bucket: Bucket{"units", "infantry", ""}, Type: "Soldier M4", Identifier: "Soldier_M4", OriginLabel: ""},
		{Bucket: Bucket{"units", "ships", "warships"}, Type: "MOSCOW", Identifier: "MOSCOW", OriginLabel: ""},
	}
	statics := []ClassifiedEntry{
		{Bucket: Bucket{"statics", "fortifications", ""}, Type: "Bunker", Identifier: "Bunker", OriginLabel: ""},
		{Bucket: Bucket{"statics", "animals", ""}, Type: "Cow", Identifier: "Cow", OriginLabel: ""},
	}
	return units, statics
}

func TestEmitUnits_outputShape(t *testing.T) {
	units, _ := sampleEmitInputs()
	var sb strings.Builder
	if err := EmitUnits(&sb, units, "fakecommit", "2026-04-30T00:00:00Z"); err != nil {
		t.Fatalf("EmitUnits: %v", err)
	}
	out := sb.String()

	mustContain := []string{
		// Header
		"-- AUTO-GENERATED",
		"dcs-lua-datamine @ fakecommit",
		"2026-04-30T00:00:00Z",
		// LuaCATS alias listing
		`---@alias sms.GroupSpawnType`,
		`---| "F-16C_50"`,
		`---| "M-1 Abrams"`,
		`---| "T-80B"`,
		// Tables — assignments (no embedded padding; spaces vary per-line)
		`sms.constants.units = sms.constants.units or {}`,
		`sms.constants.units.planes = {`,
		`F_16C_50 = "F-16C_50",`,
		`sms.constants.units.armor = {`,
		`tanks = {`,
		`T_72B = "T-72B",`,
		`T_80B = "T-80B",`,
		`M_1_Abrams = "M-1 Abrams",`,
		`ifv = {`,
		`BMP_2 = "BMP-2",`,
		`sms.constants.units.infantry = {`,
		`Soldier_M4 = "Soldier M4",`,
		`sms.constants.units.ships = {`,
		`warships = {`,
		`MOSCOW = "MOSCOW",`,
		// Origin label appears after the assignment, separated by padding
		`-- Cold War Asset Pack`,
		// origin_of helper + lookup table
		`local _origin = {`,
		`["T-80B"]`,
		`= "Cold War Asset Pack",`,
		`sms.constants.units.origin_of = function`,
	}
	for _, want := range mustContain {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q\n--- output ---\n%s", want, out)
		}
	}
}

func TestEmitUnits_alphabeticalWithinBucket(t *testing.T) {
	units, _ := sampleEmitInputs()
	var sb strings.Builder
	if err := EmitUnits(&sb, units, "x", "y"); err != nil {
		t.Fatalf("EmitUnits: %v", err)
	}
	out := sb.String()
	// Within sms.constants.units.armor.tanks, identifiers are alphabetical:
	// M_1_Abrams < T_72B < T_80B.
	idxA := strings.Index(out, `M_1_Abrams`)
	idxT72 := strings.Index(out, `T_72B`)
	idxT80 := strings.Index(out, `T_80B`)
	if idxA < 0 || idxT72 < 0 || idxT80 < 0 {
		t.Fatalf("missing tank entries in output")
	}
	if !(idxA < idxT72 && idxT72 < idxT80) {
		t.Errorf("expected M_1_Abrams < T_72B < T_80B in output, got positions %d, %d, %d", idxA, idxT72, idxT80)
	}
}

func TestEmitUnits_idempotent(t *testing.T) {
	units, _ := sampleEmitInputs()
	var a, b strings.Builder
	if err := EmitUnits(&a, units, "x", "y"); err != nil {
		t.Fatalf("EmitUnits a: %v", err)
	}
	if err := EmitUnits(&b, units, "x", "y"); err != nil {
		t.Fatalf("EmitUnits b: %v", err)
	}
	if a.String() != b.String() {
		t.Errorf("non-deterministic output across two runs")
	}
}

func TestEmitUnits_emptyCommit(t *testing.T) {
	units, _ := sampleEmitInputs()
	var sb strings.Builder
	if err := EmitUnits(&sb, units, "", "2026-05-21T00:00:00Z"); err != nil {
		t.Fatalf("EmitUnits: %v", err)
	}
	out := sb.String()
	if strings.Contains(out, "@ ") {
		t.Errorf("empty commit produced '@ ' in banner:\n%s", out)
	}
	want := "-- Source: dcs-lua-datamine (regenerated 2026-05-21T00:00:00Z)"
	if !strings.Contains(out, want) {
		t.Errorf("banner missing expected line %q\n--- output ---\n%s", want, out)
	}
}

func TestEmitStatics_outputShape(t *testing.T) {
	_, statics := sampleEmitInputs()
	var sb strings.Builder
	if err := EmitStatics(&sb, statics, "x", "y"); err != nil {
		t.Fatalf("EmitStatics: %v", err)
	}
	out := sb.String()
	mustContain := []string{
		`---@alias sms.StaticSpawnType`,
		`---| "Bunker"`,
		`---| "Cow"`,
		`sms.constants.statics = sms.constants.statics or {}`,
		`sms.constants.statics.fortifications = {`,
		`Bunker = "Bunker",`,
		`sms.constants.statics.animals = {`,
		`Cow = "Cow",`,
		`sms.constants.statics.origin_of = function`,
	}
	for _, want := range mustContain {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q\n--- output ---\n%s", want, out)
		}
	}
}
