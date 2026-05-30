package main

import "testing"

func TestMeGroupFocusCmd_FailModes(t *testing.T) {
	cases := []setterCase{
		{"no-id", []string{}, "exactly one of"},
		{"name-and-id", []string{"--name", "x", "--id", "1"}, "exactly one of"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { runFailCase(t, meGroupFocusCmd, c) })
	}
}
