package main

import (
	"fmt"
	"strconv"
	"strings"
)

// Shared color parsing for `me zone create --color`, `me zone set-color`, and
// any future verbs that take an RGBA color flag. The CLI accepts a few
// equivalent input shapes — name, "#rrggbb", or "#rrggbbaa" — and emits a
// "{ r, g, b, a }" Lua table expression with floats 0..1.
//
// Lives in its own file (rather than inside any one verb) so that the
// supported color names and the alpha-default convention are defined once.
// See `parseColorToLua` for the accepted input forms.

// namedZoneColors holds the named-color presets we accept for --color.
// All defaults use alpha = 0.15 (matches DCS's default translucent fill, set
// by TriggerZone.construct in MissionEditor/modules/Mission/TriggerZone.lua).
// User can override alpha via #rrggbbaa hex.
var namedZoneColors = map[string][4]float64{
	"red":     {1, 0, 0, 0.15},
	"green":   {0, 1, 0, 0.15},
	"blue":    {0, 0, 1, 0.15},
	"yellow":  {1, 1, 0, 0.15},
	"cyan":    {0, 1, 1, 0.15},
	"magenta": {1, 0, 1, 0.15},
	"white":   {1, 1, 1, 0.15},
	"black":   {0, 0, 0, 0.15},
	"orange":  {1, 0.5, 0, 0.15},
	"purple":  {0.5, 0, 1, 0.15},
}

// parseDrawingColorToHex converts the --color / --fill-color flag value to
// a `'0xRRGGBBAA'` Lua string literal — the format me_draw_panel uses
// internally (parseColorString in me_draw_panel.lua does
// tonumber(colorString) and bit-extracts RGBA). Returns "" if the flag is
// empty (caller should then omit the color clause and let the Lua verb
// apply the default).
//
// `defaultAlpha` is the alpha byte (0..255) used when the user didn't
// supply explicit alpha — typically 0xFF for outline colors and 0x80 for
// fill colors, matching the ME's own defaults at newPrimitiveInfo_ in
// me_draw_panel.lua.
//
// Same input shapes as parseColorToLua: named (red / blue / ...),
// "#rrggbb", or "#rrggbbaa". Returns the literal already wrapped in
// single quotes — ready to splice into a Lua arg expression.
func parseDrawingColorToHex(s string, defaultAlpha uint8) (string, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return "", nil
	}
	var r, g, b, a uint8
	if rgba, ok := namedZoneColors[strings.ToLower(s)]; ok {
		r = uint8(rgba[0]*255 + 0.5)
		g = uint8(rgba[1]*255 + 0.5)
		b = uint8(rgba[2]*255 + 0.5)
		a = defaultAlpha // override the zone-table's 0.15 alpha — drawings
		// have their own opacity convention by primitive role.
	} else {
		hex := s
		switch {
		case strings.HasPrefix(hex, "#"):
			hex = hex[1:]
		case strings.HasPrefix(hex, "0x"), strings.HasPrefix(hex, "0X"):
			hex = hex[2:]
		}
		switch len(hex) {
		case 6, 8:
		default:
			return "", fmt.Errorf("--color %q: expected name, #rrggbb / #rrggbbaa, or 0xRRGGBBAA", s)
		}
		ru, err := strconv.ParseUint(hex[0:2], 16, 8)
		if err != nil {
			return "", fmt.Errorf("--color %q: invalid red byte: %w", s, err)
		}
		gu, err := strconv.ParseUint(hex[2:4], 16, 8)
		if err != nil {
			return "", fmt.Errorf("--color %q: invalid green byte: %w", s, err)
		}
		bu, err := strconv.ParseUint(hex[4:6], 16, 8)
		if err != nil {
			return "", fmt.Errorf("--color %q: invalid blue byte: %w", s, err)
		}
		r, g, b = uint8(ru), uint8(gu), uint8(bu)
		a = defaultAlpha
		if len(hex) == 8 {
			au, err := strconv.ParseUint(hex[6:8], 16, 8)
			if err != nil {
				return "", fmt.Errorf("--color %q: invalid alpha byte: %w", s, err)
			}
			a = uint8(au)
		}
	}
	return fmt.Sprintf("'0x%02x%02x%02x%02x'", r, g, b, a), nil
}

// parseColorToLua converts the --color flag value to a "{r, g, b, a}" Lua
// table expression with floats 0..1. Returns "" if the flag is empty (caller
// should then omit the color clause and let the Lua verb apply the default).
//
// Accepts:
//   - named: red, green, blue, yellow, cyan, magenta, white, black, orange, purple
//   - "#rrggbb"   — alpha defaults to 0.15
//   - "#rrggbbaa" — explicit alpha
//   - hex without "#" prefix is also accepted
func parseColorToLua(s string) (string, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return "", nil
	}
	if rgba, ok := namedZoneColors[strings.ToLower(s)]; ok {
		return fmt.Sprintf("{ %g, %g, %g, %g }", rgba[0], rgba[1], rgba[2], rgba[3]), nil
	}
	hex := s
	switch {
	case strings.HasPrefix(hex, "#"):
		hex = hex[1:]
	case strings.HasPrefix(hex, "0x"), strings.HasPrefix(hex, "0X"):
		hex = hex[2:]
	}
	switch len(hex) {
	case 6, 8:
	default:
		return "", fmt.Errorf("--color %q: expected name, #rrggbb / #rrggbbaa, or 0xRRGGBBAA", s)
	}
	r, err := strconv.ParseUint(hex[0:2], 16, 8)
	if err != nil {
		return "", fmt.Errorf("--color %q: invalid red byte: %w", s, err)
	}
	g, err := strconv.ParseUint(hex[2:4], 16, 8)
	if err != nil {
		return "", fmt.Errorf("--color %q: invalid green byte: %w", s, err)
	}
	b, err := strconv.ParseUint(hex[4:6], 16, 8)
	if err != nil {
		return "", fmt.Errorf("--color %q: invalid blue byte: %w", s, err)
	}
	a := uint64(38) // 0.15 * 255 ≈ 38; preserves the DCS-default alpha when only RGB is given
	if len(hex) == 8 {
		av, err := strconv.ParseUint(hex[6:8], 16, 8)
		if err != nil {
			return "", fmt.Errorf("--color %q: invalid alpha byte: %w", s, err)
		}
		a = av
	}
	rf := float64(r) / 255
	gf := float64(g) / 255
	bf := float64(b) / 255
	af := float64(a) / 255
	if len(hex) == 6 {
		af = 0.15 // exact DCS default rather than 38/255
	}
	return fmt.Sprintf("{ %g, %g, %g, %g }", rf, gf, bf, af), nil
}
