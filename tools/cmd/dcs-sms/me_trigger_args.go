package main

import (
	"fmt"
	"strings"
)

// parseTriggerFieldArgs walks the trailing argv slots after a verb's known
// flags and parses `<key>=<value>` pairs. Returns map[key]value (string,
// untyped — the Lua side coerces against descriptor metadata). The first
// `=` is the separator; everything after is the value verbatim, so values
// like `text=a=b` parse correctly.
//
// Empty input → empty map (no error).
// Token without `=`, or empty key, returns an error.
func parseTriggerFieldArgs(args []string) (map[string]string, error) {
	out := make(map[string]string, len(args))
	for _, a := range args {
		i := strings.Index(a, "=")
		if i < 0 {
			return nil, fmt.Errorf("expected key=value, got %q", a)
		}
		k := a[:i]
		if k == "" {
			return nil, fmt.Errorf("empty key in %q", a)
		}
		out[k] = a[i+1:]
	}
	return out, nil
}

// buildLuaFieldsExpr renders a map[string]string as a Lua table literal:
// { ["key"] = "value", ["key2"] = "value2" }. Empty / nil map → "{}".
//
// Used by add-condition / add-action / create's bundled --condition flag
// to embed the user's field set in the runMeVerb args expression. The Lua
// side then coerces strings to typed values per descriptor.
//
// Bracket form `[<quoted>] = <quoted>` is used (rather than bare
// `key = <quoted>`) so a field id that happens to collide with a Lua
// reserved word (`end`, `function`, `local`, ...) still parses. Field
// ids are normally alphanumeric/underscore but we don't want a future
// descriptor adding such a key to silently break trigger writes.
// Values are wrapped via luaQuote (see gh#70 — Go's %q escapes
// non-printable codepoints in a form Lua doesn't decode).
func buildLuaFieldsExpr(fields map[string]string) string {
	if len(fields) == 0 {
		return "{}"
	}
	parts := make([]string, 0, len(fields))
	for k, v := range fields {
		parts = append(parts, fmt.Sprintf("[%s] = %s", luaQuote(k), luaQuote(v)))
	}
	return "{ " + strings.Join(parts, ", ") + " }"
}

// parseBundledRuleString parses a single `--condition` / `--action` value
// from `me trigger create`'s bundled form: `<predicate> <key>=<val> ...`.
// Tokens are whitespace-separated; the first is the predicate name, the
// rest are key=value pairs handled by parseTriggerFieldArgs.
//
// Limitation: values containing literal whitespace must be shell-quoted in
// the outer string OR users fall back to the composable form. This parser
// does NOT re-tokenize quoted substrings.
func parseBundledRuleString(s string) (predicate string, fields map[string]string, err error) {
	tokens := strings.Fields(strings.TrimSpace(s))
	if len(tokens) == 0 {
		return "", nil, fmt.Errorf("empty rule string")
	}
	predicate = tokens[0]
	fields, err = parseTriggerFieldArgs(tokens[1:])
	if err != nil {
		return "", nil, fmt.Errorf("rule %q: %w", s, err)
	}
	return predicate, fields, nil
}

// stringSliceFlag implements flag.Value to allow repeatable --condition /
// --action flags on `me trigger create`. Each occurrence appends to the
// underlying slice; FilePath: tools/cmd/dcs-sms/me_trigger_args.go.
type stringSliceFlag []string

func (s *stringSliceFlag) String() string {
	if s == nil {
		return ""
	}
	return strings.Join(*s, ", ")
}

func (s *stringSliceFlag) Set(v string) error {
	*s = append(*s, v)
	return nil
}
