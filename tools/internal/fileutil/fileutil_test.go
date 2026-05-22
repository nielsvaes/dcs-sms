package fileutil

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestReadFileRetry_Success(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "f")
	want := []byte("hello")
	if err := os.WriteFile(path, want, 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := ReadFileRetry(path)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if string(got) != string(want) {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestReadFileRetry_FailsFastOnNotExist(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "does-not-exist")
	start := time.Now()
	_, err := ReadFileRetry(path)
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	// Should NOT walk the full retry budget (~14ms) on a non-sharing error.
	if elapsed > 5*time.Millisecond {
		t.Errorf("appeared to retry on ErrNotExist; elapsed=%v", elapsed)
	}
}
