// Package dcspath discovers the user's DCS Saved Games folder. The Saved
// Games path is needed by every CLI subcommand to locate the dcs-sms
// mailbox.
//
// Discovery order:
//
//  1. --saved-games flag (handled by callers, passed in directly)
//  2. DCS_SMS_SAVED_GAMES environment variable
//  3. config file at the user's config dir (~/.config/dcs-sms/config.toml or
//     %AppData%\dcs-sms\config.toml)
//  4. Default: %USERPROFILE%\Saved Games\DCS or DCS.openbeta (whichever exists)
package dcspath

import (
	"bufio"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// errConfigKeyNotFound is returned by discoverConfigKey when the config file
// exists but does not contain the requested key. Discover treats it like a
// missing file (fall through to the next discovery step) rather than a hard
// failure — otherwise a config.toml holding only dcs_install (the normal
// state after install-me-mod) would dead-end every Saved Games lookup.
var errConfigKeyNotFound = errors.New("key not found in config")

// DefaultConfigPath returns the config file path for the current user.
func DefaultConfigPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "dcs-sms", "config.toml"), nil
}

// DiscoverFromEnv returns the path from the DCS_SMS_SAVED_GAMES env var.
func DiscoverFromEnv() (string, bool) {
	v := os.Getenv("DCS_SMS_SAVED_GAMES")
	if v == "" {
		return "", false
	}
	return v, true
}

// DiscoverFromConfig parses the config file and returns the saved_games
// value. Returns an error if the file is missing or the key isn't set.
func DiscoverFromConfig(configPath string) (string, error) {
	return discoverConfigKey(configPath, "saved_games")
}

// SaveConfig writes saved_games = "<path>" to configPath, creating parent
// directories as needed. Preserves any other keys (e.g. dcs_install) already
// present.
func SaveConfig(configPath, savedGamesPath string) error {
	return upsertConfigKey(configPath, "saved_games", savedGamesPath)
}

// DiscoverFromInstallEnv returns the path from the DCS_SMS_DCS_INSTALL env var.
func DiscoverFromInstallEnv() (string, bool) {
	v := os.Getenv("DCS_SMS_DCS_INSTALL")
	if v == "" {
		return "", false
	}
	return v, true
}

// DiscoverFromInstallConfig parses the config file and returns the dcs_install
// value. Returns an error if the file is missing or the key isn't set.
func DiscoverFromInstallConfig(configPath string) (string, error) {
	return discoverConfigKey(configPath, "dcs_install")
}

// SaveInstallConfig writes (or updates) the dcs_install key in configPath.
// Preserves any other keys (e.g. saved_games) already present.
func SaveInstallConfig(configPath, installPath string) error {
	return upsertConfigKey(configPath, "dcs_install", installPath)
}

// DiscoverInstall applies the priority order for DCS install dir:
//  1. override (e.g. --dcs-path flag)
//  2. DCS_SMS_DCS_INSTALL env var
//  3. configPath's dcs_install key
//
// No automatic discovery — DCS install dirs vary too much.
func DiscoverInstall(override, configPath string) (string, error) {
	if override != "" {
		return override, nil
	}
	if v, ok := DiscoverFromInstallEnv(); ok {
		return v, nil
	}
	if configPath != "" {
		v, err := DiscoverFromInstallConfig(configPath)
		if err == nil {
			return v, nil
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return "", fmt.Errorf("reading %s: %w", configPath, err)
		}
	}
	return "", errors.New("could not discover DCS install path; pass --dcs-path or set DCS_SMS_DCS_INSTALL")
}

// discoverConfigKey is the shared scanner for both saved_games and
// dcs_install.
func discoverConfigKey(configPath, key string) (string, error) {
	f, err := os.Open(configPath)
	if err != nil {
		return "", err
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		// Only full-line comments are recognized. Mid-line '#' is intentionally
		// kept as part of the value — Windows paths can contain '#', and TOML's
		// real comment rules add complexity we don't need for one key.
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		if strings.TrimSpace(k) != key {
			continue
		}
		return parseTomlString(strings.TrimSpace(v))
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	return "", fmt.Errorf("%s %w", key, errConfigKeyNotFound)
}

// upsertConfigKey writes key = "value" into configPath, replacing any prior
// line for the same key and preserving everything else. Creates the file
// (and parent dirs) if needed.
func upsertConfigKey(configPath, key, value string) error {
	if err := os.MkdirAll(filepath.Dir(configPath), 0o755); err != nil {
		return err
	}
	var existing []byte
	if data, err := os.ReadFile(configPath); err == nil {
		existing = data
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	lines := strings.Split(string(existing), "\n")
	newLine := fmt.Sprintf("%s = %s", key, encodeTomlString(value))
	found := false
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		k, _, ok := strings.Cut(trimmed, "=")
		if !ok {
			continue
		}
		if strings.TrimSpace(k) == key {
			lines[i] = newLine
			found = true
			break
		}
	}
	if !found {
		// Append, ensuring exactly one trailing newline.
		if len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) == "" {
			lines[len(lines)-1] = newLine
		} else {
			lines = append(lines, newLine)
		}
		lines = append(lines, "")
	}
	return os.WriteFile(configPath, []byte(strings.Join(lines, "\n")), 0o644)
}

// DiscoverDefault returns the DCS variant folder under the user's real
// "Saved Games" location:
//   <Saved Games>\DCS  (or DCS.openbeta / DCS.server)
// whichever exists. The Saved Games base comes from savedGamesBase(), which on
// Windows queries the Known Folder API so a relocated Saved Games (moved to
// another drive) resolves the same way DCS itself resolves it. Returns
// ("", false) if the base can't be found or no variant folder exists.
func DiscoverDefault() (string, bool) {
	base, ok := savedGamesBase()
	if !ok {
		return "", false
	}
	return pickVariantDir(base)
}

// pickVariantDir returns the first existing DCS variant subfolder under base
// (DCS, then DCS.openbeta, then DCS.server). Pure filesystem logic, split out
// so it's unit-testable without touching the real Saved Games folder.
func pickVariantDir(base string) (string, bool) {
	for _, sub := range []string{"DCS", "DCS.openbeta", "DCS.server"} {
		p := filepath.Join(base, sub)
		if info, err := os.Stat(p); err == nil && info.IsDir() {
			return p, true
		}
	}
	return "", false
}

// Discover applies the full priority order. The override argument lets a
// CLI flag take precedence over everything else.
func Discover(override, configPath string) (string, error) {
	if override != "" {
		return override, nil
	}
	if v, ok := DiscoverFromEnv(); ok {
		if info, err := os.Stat(v); err != nil || !info.IsDir() {
			return "", fmt.Errorf("DCS_SMS_SAVED_GAMES=%q is not an existing directory", v)
		}
		return v, nil
	}
	if configPath != "" {
		v, err := DiscoverFromConfig(configPath)
		if err == nil {
			return v, nil
		}
		// A missing file OR a present file without the saved_games key both mean
		// "config can't tell us" — fall through to the default discovery. Only a
		// genuine read error (permissions, scanner failure) is fatal.
		if !errors.Is(err, fs.ErrNotExist) && !errors.Is(err, errConfigKeyNotFound) {
			return "", fmt.Errorf("reading %s: %w", configPath, err)
		}
	}
	if v, ok := DiscoverDefault(); ok {
		return v, nil
	}
	return "", errors.New("could not discover DCS Saved Games path; pass --saved-games or set DCS_SMS_SAVED_GAMES")
}

// parseTomlString parses a basic-string TOML literal: "..." with \" and \\
// escapes. Only the subset we actually emit.
func parseTomlString(raw string) (string, error) {
	if len(raw) < 2 || raw[0] != '"' || raw[len(raw)-1] != '"' {
		return "", fmt.Errorf("expected quoted string, got %q", raw)
	}
	body := raw[1 : len(raw)-1]
	var out strings.Builder
	for i := 0; i < len(body); i++ {
		c := body[i]
		if c != '\\' {
			out.WriteByte(c)
			continue
		}
		if i+1 >= len(body) {
			return "", errors.New("trailing backslash in string")
		}
		switch body[i+1] {
		case '\\':
			out.WriteByte('\\')
		case '"':
			out.WriteByte('"')
		case 'n':
			out.WriteByte('\n')
		case 't':
			out.WriteByte('\t')
		default:
			return "", fmt.Errorf("unknown escape \\%c", body[i+1])
		}
		i++
	}
	return out.String(), nil
}

// encodeTomlString returns a TOML basic string for s, escaping \ and ".
func encodeTomlString(s string) string {
	var out strings.Builder
	out.WriteByte('"')
	for _, r := range s {
		switch r {
		case '\\':
			out.WriteString("\\\\")
		case '"':
			out.WriteString("\\\"")
		default:
			out.WriteRune(r)
		}
	}
	out.WriteByte('"')
	return out.String()
}

// SanitizeUserPath cleans a user-pasted path. It strips a matching
// surrounding pair of quotes (ASCII " or ', or smart "…" U+201C/U+201D /
// '…' U+2018/U+2019), then strips a single stray leading or trailing
// quote (lazy paste like `"D:\path`), then runs filepath.Clean. Empty or
// whitespace-only input returns "".
//
// Nested mid-string quotes are preserved — only the outermost matched
// pair (or one stray edge quote) is removed.
func SanitizeUserPath(s string) string {
	s = strings.TrimSpace(s)
	s = stripMatchedQuotes(s)
	s = stripStrayQuote(s)
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	return filepath.Clean(s)
}

func stripMatchedQuotes(s string) string {
	rs := []rune(s)
	if len(rs) < 2 {
		return s
	}
	pairs := [][2]rune{
		{'"', '"'},
		{'\'', '\''},
		{'“', '”'},
		{'‘', '’'},
	}
	for _, p := range pairs {
		if rs[0] == p[0] && rs[len(rs)-1] == p[1] {
			return string(rs[1 : len(rs)-1])
		}
	}
	return s
}

func stripStrayQuote(s string) string {
	rs := []rune(s)
	if len(rs) == 0 {
		return s
	}
	if isQuoteRune(rs[0]) {
		rs = rs[1:]
	}
	if len(rs) > 0 && isQuoteRune(rs[len(rs)-1]) {
		rs = rs[:len(rs)-1]
	}
	return string(rs)
}

func isQuoteRune(r rune) bool {
	switch r {
	case '"', '\'', '“', '”', '‘', '’':
		return true
	}
	return false
}
