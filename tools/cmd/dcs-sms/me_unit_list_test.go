package main

import "testing"

// TestMeUnitListTypeFlagParses confirms `--type` accepts both the single-value
// form (existing behavior) and the comma-separated any-of form (new). The
// list-expression rendering is exercised end-to-end by the manual smoke test
// against a live ME — Mav's filed gap 7 motivated this.
func TestMeUnitListTypeFlagParses(t *testing.T) {
	cases := []string{
		"F-16C_50",
		"flak18,flak36,bofors40",
		"flak18, flak36 ,bofors40",
		"flak18,",
		"",
	}
	for _, in := range cases {
		fs, opts := meUnitListFlags()
		if err := fs.Parse([]string{"--type", in}); err != nil {
			t.Errorf("--type %q parse failed: %v", in, err)
			continue
		}
		if opts.Type != in {
			t.Errorf("--type %q -> opts.Type = %q", in, opts.Type)
		}
	}
}
