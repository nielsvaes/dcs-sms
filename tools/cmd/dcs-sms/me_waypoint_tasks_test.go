package main

import (
	"bytes"
	"io"
	"strings"
	"testing"
)

func TestMeWaypointAddTaskCmd_FailModes(t *testing.T) {
	cases := []setterCase{
		{"no-id", []string{"--index", "0", "--task", "Bombing"}, "exactly one of"},
		{"no-index", []string{"--group-name", "x", "--task", "Bombing"}, "--index"},
		{"no-task", []string{"--group-name", "x", "--index", "0"}, "--task"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { runFailCase(t, meWaypointAddTaskCmd, c) })
	}
}

func TestMeWaypointAddEnrouteTaskCmd_FailModes(t *testing.T) {
	cases := []setterCase{
		{"no-id", []string{"--index", "0", "--task", "EngageTargets"}, "exactly one of"},
		{"no-index", []string{"--group-name", "x", "--task", "EngageTargets"}, "--index"},
		{"no-task", []string{"--group-name", "x", "--index", "0"}, "--task"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { runFailCase(t, meWaypointAddEnrouteTaskCmd, c) })
	}
}

func TestMeWaypointRemoveTaskCmd_FailModes(t *testing.T) {
	cases := []setterCase{
		{"no-id", []string{"--index", "0", "--slot", "1"}, "exactly one of"},
		{"no-index", []string{"--group-name", "x", "--slot", "1"}, "--index"},
		{"no-slot", []string{"--group-name", "x", "--index", "0"}, "--slot"},
		{"zero-slot", []string{"--group-name", "x", "--index", "0", "--slot", "0"}, "--slot"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { runFailCase(t, meWaypointRemoveTaskCmd, c) })
	}
}

func TestMeWaypointRemoveEnrouteTaskCmd_FailModes(t *testing.T) {
	cases := []setterCase{
		{"no-id", []string{"--index", "0", "--slot", "1"}, "exactly one of"},
		{"no-index", []string{"--group-name", "x", "--slot", "1"}, "--index"},
		{"no-slot", []string{"--group-name", "x", "--index", "0"}, "--slot"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { runFailCase(t, meWaypointRemoveEnrouteTaskCmd, c) })
	}
}

func TestMeWaypointClearTasksCmd_FailModes(t *testing.T) {
	cases := []setterCase{
		{"no-id", []string{"--index", "0"}, "exactly one of"},
		{"no-index", []string{"--group-name", "x"}, "--index"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { runFailCase(t, meWaypointClearTasksCmd, c) })
	}
}

func TestMeWaypointClearEnrouteTasksCmd_FailModes(t *testing.T) {
	cases := []setterCase{
		{"no-id", []string{"--index", "0"}, "exactly one of"},
		{"no-index", []string{"--group-name", "x"}, "--index"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { runFailCase(t, meWaypointClearEnrouteTasksCmd, c) })
	}
}

func TestMeWaypointListTasksCmd_FailModes(t *testing.T) {
	cases := []setterCase{
		{"bad-kind", []string{"--kind", "weird"}, "waypoint"},
		{"name-and-id", []string{"--group-name", "x", "--group-id", "1"}, "mutually exclusive"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { runFailCase(t, meWaypointListTasksCmd, c) })
	}
}

func TestMeWaypointDescribeTaskCmd_FailModes(t *testing.T) {
	cases := []setterCase{
		{"no-task", []string{}, "--task"},
		{"bad-kind", []string{"--task", "Bombing", "--kind", "weird"}, "waypoint"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { runFailCase(t, meWaypointDescribeTaskCmd, c) })
	}
}

// Sanity check that the lua-args expression is well-formed for the
// successful path of add-task — exercises buildLuaFieldsExpr indirectly.
// We can't actually hit the bridge (no DCS), so we just confirm the
// command rejects bridge-bound calls with exit code 3 (env) or
// similar, not 2 (CLI parse).
func TestMeWaypointAddTaskCmd_LuaArgsParseable(t *testing.T) {
	var stderr bytes.Buffer
	code := meWaypointAddTaskCmd(
		[]string{"--group-name", "x", "--index", "0", "--task", "Bombing",
			"altitude=1500", "expend=All"},
		io.Discard, &stderr,
	)
	if code == 2 {
		t.Fatalf("unexpected CLI parse failure: %s", stderr.String())
	}
	// Any of 1/3/4 (verb / env / bridge) is acceptable here — the point
	// is we didn't fail at flag parsing.
	if code == 0 {
		t.Logf("note: succeeded (live ME present); stderr=%q", stderr.String())
	}
	if strings.Contains(stderr.String(), "panic") {
		t.Errorf("panic in lua-args build: %s", stderr.String())
	}
}
