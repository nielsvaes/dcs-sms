package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meDrawingCreateLineOpts struct {
	Vertices        string
	VerticesFile    string
	Closed          bool
	LineMode        string
	Name            string
	Color           string
	Thickness       float64
	Style           string
	Layer           string
	HiddenOnPlanner bool
	Timeout         time.Duration
	Pretty          bool
	SavedGames      string
}

func meDrawingCreateLineFlags() (*flag.FlagSet, *meDrawingCreateLineOpts) {
	opts := &meDrawingCreateLineOpts{}
	fs := flag.NewFlagSet("me drawing create-line", flag.ContinueOnError)
	fs.StringVar(&opts.Vertices, "vertices", "",
		"vertices as \"n1,e1;n2,e2;...\" (>= 2 absolute world-meter pairs)")
	fs.StringVar(&opts.VerticesFile, "vertices-file", "",
		"path to a file with one \"north,east\" per line (use for long polylines that hit Windows arg-length limits); mutually exclusive with --vertices")
	fs.BoolVar(&opts.Closed, "closed", false, "close the polyline back to the first vertex")
	fs.StringVar(&opts.LineMode, "line-mode", "", "segments | segment | free (default segments)")
	fs.StringVar(&opts.Name, "name", "", "drawing name (auto-allocated if empty)")
	fs.StringVar(&opts.Color, "color", "", "line color (default red, opaque)")
	fs.Float64Var(&opts.Thickness, "thickness", 0, "line thickness in pixels (default 2)")
	fs.StringVar(&opts.Style, "style", "", "line style (default solid)")
	fs.StringVar(&opts.Layer, "layer", "", "Red|Blue|Neutral|Common|Author (default Common)")
	fs.BoolVar(&opts.HiddenOnPlanner, "hidden-on-planner", false, "hide on mission planner")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("drawing", "create-line", cmdInfo{
		Run:      meDrawingCreateLineCmd,
		Flags:    flagsOnly(meDrawingCreateLineFlags),
		Synopsis: "draw a polyline on the F10 map (segments / segment / free; --closed wraps it)",
	})
}

// meDrawingCreateLineCmd implements
// `dcs-sms me drawing create-line --vertices "n1,e1;n2,e2;..." [--closed --line-mode --color ...]`.
//
// Multi-segment line / polyline drawing. The verb computes the center
// (anchor) as the average of the supplied vertices and stores the
// points relative to that center — same convention as
// `me zone create --type quad --vertices`.
func meDrawingCreateLineCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingCreateLineFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Vertices == "" && opts.VerticesFile == "" {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-line: --vertices or --vertices-file is required")
		return 2
	}
	if opts.Vertices != "" && opts.VerticesFile != "" {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-line: --vertices and --vertices-file are mutually exclusive")
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
		fmt.Fprintln(stderr, "dcs-sms me drawing create-line:", err)
		return 2
	}

	colorLua, err := parseDrawingColorToHex(opts.Color, 0xFF)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-line:", err)
		return 2
	}

	parts := []string{
		"vertices = " + verticesLua,
	}
	if opts.Closed {
		parts = append(parts, "closed = true")
	}
	if opts.LineMode != "" {
		parts = append(parts, fmt.Sprintf("line_mode = %q", opts.LineMode))
	}
	if opts.Name != "" {
		parts = append(parts, fmt.Sprintf("name = %q", opts.Name))
	}
	if colorLua != "" {
		parts = append(parts, "color = "+colorLua)
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

	resp, exitCode := runMeVerb("drawing_create_line", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
