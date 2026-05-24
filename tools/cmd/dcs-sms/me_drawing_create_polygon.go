package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meDrawingCreatePolygonOpts struct {
	Vertices        string
	VerticesFile    string
	Name            string
	Color           string
	FillColor       string
	Thickness       float64
	Style           string
	Layer           string
	HiddenOnPlanner bool
	Timeout         time.Duration
	Pretty          bool
	SavedGames      string
}

func meDrawingCreatePolygonFlags() (*flag.FlagSet, *meDrawingCreatePolygonOpts) {
	opts := &meDrawingCreatePolygonOpts{}
	fs := flag.NewFlagSet("me drawing create-polygon", flag.ContinueOnError)
	fs.StringVar(&opts.Vertices, "vertices", "",
		"vertices as \"n1,e1;n2,e2;...\" (>= 3 absolute world-meter pairs)")
	fs.StringVar(&opts.VerticesFile, "vertices-file", "",
		"path to a file with one \"north,east\" per line (use for large polygons that hit Windows arg-length limits); mutually exclusive with --vertices")
	fs.StringVar(&opts.Name, "name", "", "drawing name (auto-allocated if empty)")
	fs.StringVar(&opts.Color, "color", "", "outline color (default red, opaque)")
	fs.StringVar(&opts.FillColor, "fill-color", "", "fill color (default red, half alpha)")
	fs.Float64Var(&opts.Thickness, "thickness", 0, "outline thickness in pixels (default 2)")
	fs.StringVar(&opts.Style, "style", "", "line style (default solid)")
	fs.StringVar(&opts.Layer, "layer", "", "Red|Blue|Neutral|Common|Author (default Common)")
	fs.BoolVar(&opts.HiddenOnPlanner, "hidden-on-planner", false, "hide on mission planner")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("drawing", "create-polygon", cmdInfo{
		Run:      meDrawingCreatePolygonCmd,
		Flags:    flagsOnly(meDrawingCreatePolygonFlags),
		Synopsis: "draw a free-mode polygon on the F10 map",
	})
}

// meDrawingCreatePolygonCmd implements
// `dcs-sms me drawing create-polygon --vertices "n1,e1;n2,e2;..." [...]`.
//
// Free-shape polygon (closed, filled). For analytic shapes (circle,
// rect, oval, arrow) use the dedicated create-* verbs which take
// dimension fields instead of explicit vertices.
func meDrawingCreatePolygonCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingCreatePolygonFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Vertices == "" && opts.VerticesFile == "" {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-polygon: --vertices or --vertices-file is required")
		return 2
	}
	if opts.Vertices != "" && opts.VerticesFile != "" {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-polygon: --vertices and --vertices-file are mutually exclusive")
		return 2
	}
	var verticesLua string
	var err error
	if opts.VerticesFile != "" {
		verticesLua, err = parseVerticesFileToLua(opts.VerticesFile)
	} else {
		verticesLua, err = parseVerticesToLua(opts.Vertices)
	}
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-polygon:", err)
		return 2
	}

	colorLua, err := parseDrawingColorToHex(opts.Color, 0xFF)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-polygon:", err)
		return 2
	}
	fillLua, err := parseDrawingColorToHex(opts.FillColor, 0x80)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-polygon:", err)
		return 2
	}

	parts := []string{
		"vertices = " + verticesLua,
	}
	if opts.Name != "" {
		parts = append(parts, fmt.Sprintf("name = %q", opts.Name))
	}
	if colorLua != "" {
		parts = append(parts, "color = "+colorLua)
	}
	if fillLua != "" {
		parts = append(parts, "fill_color = "+fillLua)
	}
	if opts.Thickness > 0 {
		parts = append(parts, fmt.Sprintf("thickness = %g", opts.Thickness))
	}
	if opts.Style != "" {
		parts = append(parts, fmt.Sprintf("style = %q", opts.Style))
	}
	if opts.Layer != "" {
		parts = append(parts, fmt.Sprintf("layer = %q", opts.Layer))
	}
	if opts.HiddenOnPlanner {
		parts = append(parts, "hidden_on_planner = true")
	}
	luaArgs := "{ " + strings.Join(parts, ", ") + " }"

	resp, exitCode := runMeVerb("drawing_create_polygon", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
