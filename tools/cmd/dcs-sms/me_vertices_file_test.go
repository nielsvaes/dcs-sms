package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeTempFile(t *testing.T, name, content string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(content), 0644); err != nil {
		t.Fatalf("write temp file: %v", err)
	}
	return p
}

func TestParseVerticesFileToLua_PlainTriplet(t *testing.T) {
	p := writeTempFile(t, "tri.txt", "100,200\n300,400\n500,600\n")
	got, err := parseVerticesFileToLua(p)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := "{ { north = 100, east = 200 }, { north = 300, east = 400 }, { north = 500, east = 600 } }"
	if got != want {
		t.Errorf("got %q\nwant %q", got, want)
	}
}

func TestParseVerticesFileToLua_SkipsBlanksAndComments(t *testing.T) {
	body := `# header comment

100, 200
# blank below

300,400
`
	p := writeTempFile(t, "skip.txt", body)
	got, err := parseVerticesFileToLua(p)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(got, "north = 100") || !strings.Contains(got, "north = 300") {
		t.Errorf("missing expected vertices in %q", got)
	}
	if strings.Count(got, "{ north") != 2 {
		t.Errorf("expected 2 vertices, got %q", got)
	}
}

func TestParseVerticesFileToLua_HandlesCRLF(t *testing.T) {
	p := writeTempFile(t, "crlf.txt", "100,200\r\n300,400\r\n")
	got, err := parseVerticesFileToLua(p)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if strings.Count(got, "{ north") != 2 {
		t.Errorf("CRLF not handled: got %q", got)
	}
}

func TestParseVerticesFileToLua_RejectsEmpty(t *testing.T) {
	p := writeTempFile(t, "empty.txt", "# only comments\n\n")
	_, err := parseVerticesFileToLua(p)
	if err == nil {
		t.Fatal("expected error on empty/comment-only file")
	}
}

func TestParseVerticesFileToLua_ReportsLineNumber(t *testing.T) {
	p := writeTempFile(t, "bad.txt", "100,200\nbogus\n300,400\n")
	_, err := parseVerticesFileToLua(p)
	if err == nil {
		t.Fatal("expected error on malformed line")
	}
	if !strings.Contains(err.Error(), "line 2") {
		t.Errorf("error should mention line 2, got %v", err)
	}
}

func TestParseVerticesFileToLua_MissingFile(t *testing.T) {
	_, err := parseVerticesFileToLua(filepath.Join(t.TempDir(), "nope.txt"))
	if err == nil {
		t.Fatal("expected error on missing file")
	}
}
