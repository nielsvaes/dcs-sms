package main

import (
	"bytes"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDocCmdGeneratesIndexAndPages(t *testing.T) {
	// Run docCmd against a temp dir, assert the index + at least one
	// per-command page got written. Uses the real registry so this also
	// exercises that the docs subsystem can iterate everything that other
	// init() blocks have registered.
	tmp := t.TempDir()

	var stdout, stderr bytes.Buffer
	code := docCmd([]string{"-out", tmp}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("docCmd exit %d, stderr=%q", code, stderr.String())
	}

	indexPath := filepath.Join(tmp, "README.md")
	idx, err := os.ReadFile(indexPath)
	if err != nil {
		t.Fatalf("missing index: %v", err)
	}
	if !strings.Contains(string(idx), "dcs-sms CLI reference") {
		t.Errorf("index missing title, got %q", string(idx))
	}
	if !strings.Contains(string(idx), "[`exec`](exec.md)") {
		t.Errorf("index missing exec link, got %q", string(idx))
	}

	execPath := filepath.Join(tmp, "exec.md")
	ex, err := os.ReadFile(execPath)
	if err != nil {
		t.Fatalf("missing exec page: %v", err)
	}
	if !strings.Contains(string(ex), "`dcs-sms exec`") {
		t.Errorf("exec page missing title, got %q", string(ex))
	}
	if !strings.Contains(string(ex), "--target") {
		t.Errorf("exec page missing --target flag, got %q", string(ex))
	}
}

func TestFlagTypeStandardKinds(t *testing.T) {
	fs := flag.NewFlagSet("t", flag.ContinueOnError)
	var s string
	var i int
	var b bool
	fs.StringVar(&s, "s", "", "")
	fs.IntVar(&i, "i", 0, "")
	fs.BoolVar(&b, "b", false, "")

	got := map[string]string{}
	fs.VisitAll(func(f *flag.Flag) {
		got[f.Name] = flagType(f)
	})
	if got["s"] != "string" {
		t.Errorf("string: got %q, want %q", got["s"], "string")
	}
	if got["i"] != "int" {
		t.Errorf("int: got %q, want %q", got["i"], "int")
	}
	if got["b"] != "bool" {
		t.Errorf("bool: got %q, want %q", got["b"], "bool")
	}
}

func TestFlagTypeStringSliceFlag(t *testing.T) {
	fs := flag.NewFlagSet("t", flag.ContinueOnError)
	var sl stringSliceFlag
	fs.Var(&sl, "set", "")
	var got string
	fs.VisitAll(func(f *flag.Flag) { got = flagType(f) })
	if got != "string (repeatable)" {
		t.Errorf("stringSliceFlag: got %q, want %q", got, "string (repeatable)")
	}
}

// A cmdInfo with SubCommands renders one flags table per sub-verb, and the
// usage line lists the sub-verb names. Guards the gh #68 doc-gen fix.
func TestBuildPageRendersSubCommands(t *testing.T) {
	setFlags := func() *flag.FlagSet {
		fs := flag.NewFlagSet("set", flag.ContinueOnError)
		fs.String("weapon", "", "weapon clsid")
		return fs
	}
	fuzeFlags := func() *flag.FlagSet {
		fs := flag.NewFlagSet("set-fuze", flag.ContinueOnError)
		var sl stringSliceFlag
		fs.Var(&sl, "set", "key=value pair")
		return fs
	}
	info := cmdInfo{
		// Run is unused by buildPage/renderPage; leave nil.
		Synopsis: "manage payload",
		SubCommands: []subCommand{
			{Name: "set", Synopsis: "set a weapon", Flags: setFlags},
			{Name: "set-fuze", Synopsis: "set fuze settings", Flags: fuzeFlags},
		},
	}
	page := buildPage("me unit payload", "me unit", info)
	if len(page.SubVerbs) != 2 {
		t.Fatalf("got %d sub-verbs, want 2", len(page.SubVerbs))
	}
	if page.SubVerbs[1].Name != "set-fuze" || len(page.SubVerbs[1].Flags) != 1 {
		t.Errorf("set-fuze sub-verb: %+v", page.SubVerbs[1])
	}

	out := renderPage(page)
	for _, want := range []string{
		"dcs-sms me unit payload <set|set-fuze> [flags]",
		"## `set`",
		"## `set-fuze`",
		"set fuze settings",
		"| `--set` | string (repeatable) |",
		"| `--weapon` | string |",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("rendered page missing %q\n---\n%s", want, out)
		}
	}
}
