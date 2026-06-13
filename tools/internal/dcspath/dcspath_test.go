package dcspath

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Bug #1 regression: a config.toml that exists but has no saved_games key
// (the normal state after install-me-mod writes only dcs_install) must NOT
// hard-fail Discover — it has to fall through to the default discovery.
// Before the fix, Discover returned "reading <cfg>: saved_games key not found
// in config", which broke the LuaSec lib copy on update and the hook install.
func TestDiscover_FallsThroughWhenConfigMissingKey(t *testing.T) {
	t.Setenv("DCS_SMS_SAVED_GAMES", "") // isolate from the host env
	dir := t.TempDir()
	cfg := filepath.Join(dir, "config.toml")
	// Config has dcs_install but no saved_games — exactly what install-me-mod
	// leaves behind.
	if err := os.WriteFile(cfg, []byte(`dcs_install = "C:\\Games\\DCS World"`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := Discover("", cfg)
	// Whether DiscoverDefault then succeeds or not is environment-dependent;
	// the contract under test is only that we did NOT dead-end on the missing
	// key.
	if err != nil && errors.Is(err, errConfigKeyNotFound) {
		t.Fatalf("Discover must fall through past a missing config key, got: %v", err)
	}
	if err != nil && strings.Contains(err.Error(), "key not found in config") {
		t.Fatalf("Discover leaked the config-key error instead of falling through: %v", err)
	}
}

func TestPickVariantDir(t *testing.T) {
	base := t.TempDir()
	// Nothing present yet → no variant.
	if _, ok := pickVariantDir(base); ok {
		t.Fatal("expected no variant when base is empty")
	}
	// DCS.openbeta only → picked.
	if err := os.MkdirAll(filepath.Join(base, "DCS.openbeta"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got, ok := pickVariantDir(base); !ok || got != filepath.Join(base, "DCS.openbeta") {
		t.Fatalf("expected DCS.openbeta, got %q ok=%v", got, ok)
	}
	// DCS takes priority once it exists.
	if err := os.MkdirAll(filepath.Join(base, "DCS"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got, ok := pickVariantDir(base); !ok || got != filepath.Join(base, "DCS") {
		t.Fatalf("expected DCS to win, got %q ok=%v", got, ok)
	}
}

func TestDiscoverFromConfig(t *testing.T) {
	configDir := t.TempDir()
	savedGames := t.TempDir()
	configPath := filepath.Join(configDir, "config.toml")

	content := `saved_games = ` + tomlString(savedGames) + "\n"
	if err := os.WriteFile(configPath, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	got, err := DiscoverFromConfig(configPath)
	if err != nil {
		t.Fatalf("DiscoverFromConfig: %v", err)
	}
	if got != savedGames {
		t.Errorf("got %q want %q", got, savedGames)
	}
}

func TestDiscoverFromEnv(t *testing.T) {
	want := t.TempDir()
	t.Setenv("DCS_SMS_SAVED_GAMES", want)
	got, ok := DiscoverFromEnv()
	if !ok {
		t.Fatal("expected ok=true with env var set")
	}
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestSaveConfig(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "subdir", "config.toml")
	if err := SaveConfig(configPath, "C:\\Users\\X\\Saved Games\\DCS"); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	got, err := DiscoverFromConfig(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if got != "C:\\Users\\X\\Saved Games\\DCS" {
		t.Errorf("round-trip failed: got %q", got)
	}
}

// tomlString quotes a string for TOML, escaping backslashes and quotes.
func tomlString(s string) string {
	out := "\""
	for _, r := range s {
		switch r {
		case '\\':
			out += "\\\\"
		case '"':
			out += "\\\""
		default:
			out += string(r)
		}
	}
	return out + "\""
}

func TestParseTomlString(t *testing.T) {
	cases := []struct {
		name    string
		raw     string
		want    string
		wantErr bool
	}{
		{"plain", `"hello"`, "hello", false},
		{"backslash escape", `"a\\b"`, `a\b`, false},
		{"quote escape", `"he said \"hi\""`, `he said "hi"`, false},
		{"newline escape", `"line1\nline2"`, "line1\nline2", false},
		{"tab escape", `"a\tb"`, "a\tb", false},
		{"unquoted error", `hello`, "", true},
		{"trailing backslash error", `"foo\`, "", true},
		{"unknown escape error", `"\z"`, "", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parseTomlString(tc.raw)
			if tc.wantErr {
				if err == nil {
					t.Errorf("expected error, got %q", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Errorf("got %q want %q", got, tc.want)
			}
		})
	}
}

func TestDiscoverFromInstallEnv(t *testing.T) {
	t.Setenv("DCS_SMS_DCS_INSTALL", "")
	if _, ok := DiscoverFromInstallEnv(); ok {
		t.Fatal("expected ok=false when env var unset")
	}
	t.Setenv("DCS_SMS_DCS_INSTALL", `D:\Program Files\Eagle Dynamics\DCS World`)
	v, ok := DiscoverFromInstallEnv()
	if !ok || v != `D:\Program Files\Eagle Dynamics\DCS World` {
		t.Fatalf("got (%q, %v), want (D:\\..., true)", v, ok)
	}
}

func TestDiscoverFromInstallConfig_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "config.toml")
	want := `D:\Program Files\Eagle Dynamics\DCS World`
	if err := SaveInstallConfig(cfg, want); err != nil {
		t.Fatal(err)
	}
	got, err := DiscoverFromInstallConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestSaveInstallConfig_PreservesSavedGamesKey(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "config.toml")
	if err := SaveConfig(cfg, `C:\Users\X\Saved Games\DCS`); err != nil {
		t.Fatal(err)
	}
	if err := SaveInstallConfig(cfg, `D:\Program Files\Eagle Dynamics\DCS World`); err != nil {
		t.Fatal(err)
	}
	sg, err := DiscoverFromConfig(cfg)
	if err != nil {
		t.Fatalf("saved_games lost after writing dcs_install: %v", err)
	}
	if sg != `C:\Users\X\Saved Games\DCS` {
		t.Fatalf("saved_games clobbered: got %q", sg)
	}
	inst, err := DiscoverFromInstallConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if inst != `D:\Program Files\Eagle Dynamics\DCS World` {
		t.Fatalf("dcs_install wrong: got %q", inst)
	}
}

func TestDiscoverInstall_PriorityOrder(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "config.toml")
	if err := SaveInstallConfig(cfg, `C:\from-config`); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DCS_SMS_DCS_INSTALL", `D:\from-env`)

	// Override wins.
	got, err := DiscoverInstall(`E:\from-flag`, cfg)
	if err != nil || got != `E:\from-flag` {
		t.Fatalf("override should win, got (%q, %v)", got, err)
	}

	// Env wins over config.
	got, err = DiscoverInstall("", cfg)
	if err != nil || got != `D:\from-env` {
		t.Fatalf("env should win, got (%q, %v)", got, err)
	}

	// Config wins when env unset.
	t.Setenv("DCS_SMS_DCS_INSTALL", "")
	got, err = DiscoverInstall("", cfg)
	if err != nil || got != `C:\from-config` {
		t.Fatalf("config fallback, got (%q, %v)", got, err)
	}

	// Nothing → error.
	got, err = DiscoverInstall("", filepath.Join(dir, "missing.toml"))
	if err == nil {
		t.Fatalf("expected error when no source provided, got %q", got)
	}
}

func TestSanitizeUserPath(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"bare", `D:\Eagle Dynamics\DCS World`, `D:\Eagle Dynamics\DCS World`},
		{"ascii double quotes", `"D:\Program Files\Eagle Dynamics\DCS World"`, `D:\Program Files\Eagle Dynamics\DCS World`},
		{"ascii single quotes", `'D:\Program Files\Eagle Dynamics\DCS World'`, `D:\Program Files\Eagle Dynamics\DCS World`},
		{"smart double quotes", "“D:\\Eagle Dynamics\\DCS World”", `D:\Eagle Dynamics\DCS World`},
		{"smart single quotes", "‘D:\\Eagle Dynamics\\DCS World’", `D:\Eagle Dynamics\DCS World`},
		{"stray leading double", `"D:\Eagle Dynamics\DCS World`, `D:\Eagle Dynamics\DCS World`},
		{"stray trailing double", `D:\Eagle Dynamics\DCS World"`, `D:\Eagle Dynamics\DCS World`},
		{"stray leading smart double", "“D:\\Eagle Dynamics\\DCS World", `D:\Eagle Dynamics\DCS World`},
		{"surrounding whitespace and quotes", `   "D:\Eagle Dynamics\DCS World"   `, `D:\Eagle Dynamics\DCS World`},
		{"trailing separator", `D:\Eagle Dynamics\DCS World\`, `D:\Eagle Dynamics\DCS World`},
		{"empty", ``, ``},
		{"only whitespace", `   `, ``},
		{"only quotes", `""`, ``},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := SanitizeUserPath(tc.in)
			if got != tc.want {
				t.Errorf("SanitizeUserPath(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}
