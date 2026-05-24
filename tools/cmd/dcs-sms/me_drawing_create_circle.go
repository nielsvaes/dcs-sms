package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meDrawingCreateCircleOpts struct {
	North           float64
	East            float64
	Radius          float64
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

func meDrawingCreateCircleFlags() (*flag.FlagSet, *meDrawingCreateCircleOpts) {
	opts := &meDrawingCreateCircleOpts{}
	fs := flag.NewFlagSet("me drawing create-circle", flag.ContinueOnError)
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin")
	fs.Float64Var(&opts.Radius, "radius", 0, "radius in meters")
	fs.StringVar(&opts.Name, "name", "", "drawing name (auto-allocated if empty)")
	fs.StringVar(&opts.Color, "color", "", "outline color: name, #rrggbb (alpha=0xff), #rrggbbaa, or 0xRRGGBBAA")
	fs.StringVar(&opts.FillColor, "fill-color", "", "fill color: name, #rrggbb (alpha=0x80), #rrggbbaa, or 0xRRGGBBAA")
	fs.Float64Var(&opts.Thickness, "thickness", 0, "outline thickness in pixels (default 2)")
	fs.StringVar(&opts.Style, "style", "", "line style: solid|solid2|dot|dot2|dotdash|dash|cross|square|strongpoint|triangle|wirefence|boundry1..5 (default solid)")
	fs.StringVar(&opts.Layer, "layer", "", "layer: Red|Blue|Neutral|Common|Author (default Common)")
	fs.BoolVar(&opts.HiddenOnPlanner, "hidden-on-planner", false, "hide on mission planner")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("drawing", "create-circle", cmdInfo{
		Run:      meDrawingCreateCircleCmd,
		Flags:    flagsOnly(meDrawingCreateCircleFlags),
		Synopsis: "draw a circle on the F10 map",
	})
}

// meDrawingCreateCircleCmd implements
// `dcs-sms me drawing create-circle --north <m> --east <m> --radius <m> [...]`.
//
// Disk-shape polygon — filled disc with outline. Colors accept the same
// shapes as `me zone create --color`: name (red / blue / ...),
// "#rrggbb", or "#rrggbbaa". Outline default alpha is 0xFF (opaque),
// fill default alpha is 0x80 (half) — matches the ME's own new-primitive
// defaults. Layer defaults to Common.
func meDrawingCreateCircleCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingCreateCircleFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Radius <= 0 {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-circle: --radius is required (> 0)")
		return 2
	}

	colorLua, err := parseDrawingColorToHex(opts.Color, 0xFF)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-circle:", err)
		return 2
	}
	fillLua, err := parseDrawingColorToHex(opts.FillColor, 0x80)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-circle:", err)
		return 2
	}

	parts := []string{
		fmt.Sprintf("north = %g", opts.North),
		fmt.Sprintf("east = %g", opts.East),
		fmt.Sprintf("radius = %g", opts.Radius),
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

	resp, exitCode := runMeVerb("drawing_create_circle", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
