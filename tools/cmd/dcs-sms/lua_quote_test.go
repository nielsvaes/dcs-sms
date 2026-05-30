package main

import "testing"

// luaQuote must produce a Lua 5.1 string literal whose decoded byte sequence
// equals the input bytes — including UTF-8 sequences for non-printable
// codepoints that Go's `%q` would otherwise escape with Go-syntax `\uXXXX`
// (which Lua 5.1 doesn't understand). See gh#70.
func TestLuaQuote(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "empty",
			in:   "",
			want: `""`,
		},
		{
			name: "plain ascii",
			in:   "hello",
			want: `"hello"`,
		},
		{
			name: "embedded double quote",
			in:   `say "hi"`,
			want: `"say \"hi\""`,
		},
		{
			name: "embedded backslash",
			in:   `path\to\file`,
			want: `"path\\to\\file"`,
		},
		{
			name: "newline",
			in:   "a\nb",
			want: `"a\nb"`,
		},
		{
			name: "ascii control SOH (0x01)",
			in:   "\x01",
			want: `"\1"`,
		},
		{
			name: "ascii control followed by digit needs 3-digit form",
			in:   "\x01" + "2",
			want: `"\0012"`,
		},
		// The bug case from gh#70: U+008F is the C1 control "High Octet Preset".
		// UTF-8 encoding is 0xC2 0x8F. Go's %q escapes it to `` (Go syntax)
		// because unicode.IsPrint(0x008F) is false. Lua 5.1 doesn't recognize
		// `\u` and drops the backslash, leaving the literal chars "u008f".
		// luaQuote must instead pass the UTF-8 bytes through verbatim so Lua
		// sees them as the 2-byte sequence and stores them as such.
		{
			name: "C1 control U+008F as raw UTF-8 bytes",
			in:   "AB",
			want: "\"A\xc2\x8fB\"",
		},
		{
			name: "cyrillic passes through as UTF-8",
			in:   "ЯГ",
			want: "\"\xd0\xaf\xd0\x93\"",
		},
		{
			name: "astral emoji (4-byte UTF-8) passes through",
			in:   "\U0001F985", // eagle
			want: "\"\xf0\x9f\xa6\x85\"",
		},
		{
			name: "DEL (0x7F) is escaped",
			in:   "a\x7fb",
			want: `"a\127b"`,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := luaQuote(tt.in)
			if got != tt.want {
				t.Errorf("luaQuote(%q):\n  got:  %q  (bytes: % x)\n  want: %q  (bytes: % x)",
					tt.in, got, got, tt.want, tt.want)
			}
		})
	}
}
