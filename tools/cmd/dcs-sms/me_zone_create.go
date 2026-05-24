package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"
)

type meZoneCreateOpts struct {
	Type       string
	Name       string
	North      float64
	East       float64
	Radius     float64
	Vertices   string
	Color      string
	Hidden     bool
	Timeout    time.Duration
	Pretty     bool
	SavedGames string
}

func meZoneCreateFlags() (*flag.FlagSet, *meZoneCreateOpts) {
	opts := &meZoneCreateOpts{}
	fs := flag.NewFlagSet("me zone create", flag.ContinueOnError)
	fs.StringVar(&opts.Type, "type", "", "shape: circle | quad")
	fs.StringVar(&opts.Name, "name", "", "zone name (uniquified by ME if duplicate)")
	fs.Float64Var(&opts.North, "north", 0, "circle: meters north of theatre origin (north positive)")
	fs.Float64Var(&opts.East, "east", 0, "circle: meters east of theatre origin (east positive)")
	fs.Float64Var(&opts.Radius, "radius", 0, "circle: radius in meters; quad: optional icon radius")
	fs.StringVar(&opts.Vertices, "vertices", "",
		"quad: 4 corners as \"n1,e1;n2,e2;n3,e3;n4,e4\" (>= 3 corners actually allowed)")
	fs.StringVar(&opts.Color, "color", "",
		"color: name (red/green/blue/yellow/cyan/magenta/white/black/orange/purple), "+
			"hex \"#rrggbb\" (alpha 0.15), or \"#rrggbbaa\"; default = translucent white")
	fs.BoolVar(&opts.Hidden, "hidden", false, "hide the zone in the ME view")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("zone", "create", cmdInfo{
		Run:      meZoneCreateCmd,
		Flags:    flagsOnly(meZoneCreateFlags),
		Synopsis: "create a circular or quadrilateral zone in the open mission",
	})
}

// meZoneCreateCmd implements `dcs-sms me zone create --type circle|quad ...`.
//
// Two shapes share one subcommand because a zone is conceptually one thing
// with a shape variant; the --type flag picks circle (radius around a point)
// or quad (4-vertex polygon).
//
// Coordinates use the project's standard --north / --east meters convention
// (see top of verbs.lua for rationale). Circle takes --north / --east /
// --radius; quad takes --vertices "n1,e1;n2,e2;n3,e3;n4,e4".
func meZoneCreateCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meZoneCreateFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Name == "" {
		fmt.Fprintln(stderr, "dcs-sms me zone create: --name is required")
		return 2
	}

	colorLua, err := parseColorToLua(opts.Color)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me zone create:", err)
		return 2
	}
	colorClause := ""
	if colorLua != "" {
		colorClause = ", color = " + colorLua
	}

	switch strings.ToLower(opts.Type) {
	case "circle":
		if opts.Radius <= 0 {
			fmt.Fprintln(stderr, "dcs-sms me zone create --type circle: --radius is required (> 0)")
			return 2
		}
		luaArgs := fmt.Sprintf(
			"{ name = %q, north = %g, east = %g, radius = %g, hidden = %t%s }",
			opts.Name, opts.North, opts.East, opts.Radius, opts.Hidden, colorClause,
		)
		resp, exitCode := runMeVerb("zone_create_circle", luaArgs, opts.Timeout, opts.SavedGames, stderr)
		if exitCode != 0 {
			return exitCode
		}
		return emitMeResponse(resp, opts.Pretty, stdout)

	case "quad":
		if opts.Vertices == "" {
			fmt.Fprintln(stderr, "dcs-sms me zone create --type quad: --vertices is required (\"n1,e1;n2,e2;n3,e3;n4,e4\")")
			return 2
		}
		verticesLua, err := parseVerticesToLua(opts.Vertices)
		if err != nil {
			fmt.Fprintln(stderr, "dcs-sms me zone create --type quad:", err)
			return 2
		}
		// --radius is optional for quad; pass 0 → verb computes default.
		luaArgs := fmt.Sprintf(
			"{ name = %q, vertices = %s, radius = %g, hidden = %t%s }",
			opts.Name, verticesLua, opts.Radius, opts.Hidden, colorClause,
		)
		resp, exitCode := runMeVerb("zone_create_quad", luaArgs, opts.Timeout, opts.SavedGames, stderr)
		if exitCode != 0 {
			return exitCode
		}
		return emitMeResponse(resp, opts.Pretty, stdout)

	case "":
		fmt.Fprintln(stderr, "dcs-sms me zone create: --type is required (circle | quad)")
		return 2
	default:
		fmt.Fprintf(stderr, "dcs-sms me zone create: unknown --type %q (expected circle or quad)\n", opts.Type)
		return 2
	}
}

// parseVerticesToLua converts "n1,e1;n2,e2;n3,e3;n4,e4" into a Lua table
// expression "{ {north=n1,east=e1}, {north=n2,east=e2}, ... }".
//
// Per-shape minimum vertex count is enforced Lua-side (zone quad needs
// >= 3; line drawing >= 2; free polygon >= 3). This parser only checks
// that the string isn't empty so all callers can share it.
func parseVerticesToLua(s string) (string, error) {
	if strings.TrimSpace(s) == "" {
		return "", fmt.Errorf("--vertices is empty")
	}
	parts := strings.Split(s, ";")
	var b strings.Builder
	b.WriteString("{ ")
	for i, p := range parts {
		coords := strings.Split(strings.TrimSpace(p), ",")
		if len(coords) != 2 {
			return "", fmt.Errorf("vertex %d: expected \"north,east\", got %q", i+1, p)
		}
		north, err := strconv.ParseFloat(strings.TrimSpace(coords[0]), 64)
		if err != nil {
			return "", fmt.Errorf("vertex %d north: %w", i+1, err)
		}
		east, err := strconv.ParseFloat(strings.TrimSpace(coords[1]), 64)
		if err != nil {
			return "", fmt.Errorf("vertex %d east: %w", i+1, err)
		}
		if i > 0 {
			b.WriteString(", ")
		}
		fmt.Fprintf(&b, "{ north = %g, east = %g }", north, east)
	}
	b.WriteString(" }")
	return b.String(), nil
}

// parseVerticesFileToLua reads a file containing one "north,east" pair per
// line and returns the same Lua-table expression parseVerticesToLua emits.
// This exists so callers can sidestep the Windows CreateProcess 32 KB
// argument-length limit for polygons with hundreds of vertices (Shapely
// unions, free-form coastlines, etc.).
//
// Format:
//   - one vertex per line: "<north>,<east>"
//   - blank lines and lines starting with "#" are ignored
//   - leading/trailing whitespace per line is trimmed
func parseVerticesFileToLua(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("--vertices-file %q: %w", path, err)
	}
	var b strings.Builder
	b.WriteString("{ ")
	count := 0
	// Normalize CRLF -> LF so Windows-authored files split cleanly.
	for lineNo, raw := range strings.Split(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		coords := strings.Split(line, ",")
		if len(coords) != 2 {
			return "", fmt.Errorf("--vertices-file %q line %d: expected \"north,east\", got %q",
				path, lineNo+1, line)
		}
		north, err := strconv.ParseFloat(strings.TrimSpace(coords[0]), 64)
		if err != nil {
			return "", fmt.Errorf("--vertices-file %q line %d north: %w", path, lineNo+1, err)
		}
		east, err := strconv.ParseFloat(strings.TrimSpace(coords[1]), 64)
		if err != nil {
			return "", fmt.Errorf("--vertices-file %q line %d east: %w", path, lineNo+1, err)
		}
		if count > 0 {
			b.WriteString(", ")
		}
		fmt.Fprintf(&b, "{ north = %g, east = %g }", north, east)
		count++
	}
	if count == 0 {
		return "", fmt.Errorf("--vertices-file %q: no vertices found (file is empty or all-comments)", path)
	}
	b.WriteString(" }")
	return b.String(), nil
}
