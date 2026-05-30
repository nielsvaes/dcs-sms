package main

import (
	"strconv"
	"strings"
)

// luaQuote returns a Lua 5.1 string literal (with surrounding double quotes)
// whose decoded byte sequence equals s.
//
// Use this instead of Go's fmt `%q` when building Lua source code from user
// input. `%q` escapes any codepoint with !unicode.IsPrint using Go-syntax
// `\uXXXX`, which Lua 5.1 doesn't understand — Lua silently drops the
// backslash and the literal text "uXXXX" survives into the resulting Lua
// string, corrupting C1 controls, bidi marks, ZWJ, soft hyphens, etc. See
// gh#70 for the round-trip repro on U+008F.
//
// Bytes 0x20-0x7E (printable ASCII except `\` and `"`) and 0x80-0xFF
// (UTF-8 continuation/lead bytes) pass through verbatim. Bytes 0x00-0x1F
// and 0x7F are emitted as Lua's `\ddd` decimal escape, padded to three
// digits when followed by an ASCII digit to disambiguate.
func luaQuote(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '\\':
			b.WriteString(`\\`)
		case '"':
			b.WriteString(`\"`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if c < 0x20 || c == 0x7f {
				b.WriteByte('\\')
				d := strconv.Itoa(int(c))
				if i+1 < len(s) && s[i+1] >= '0' && s[i+1] <= '9' {
					for k := 0; k < 3-len(d); k++ {
						b.WriteByte('0')
					}
				}
				b.WriteString(d)
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}
