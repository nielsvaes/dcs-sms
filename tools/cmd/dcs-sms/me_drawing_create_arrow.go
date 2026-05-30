package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meDrawingCreateArrowOpts struct {
	North		float64
	East		float64
	Length		float64
	Angle		float64
	Name		string
	Color		string
	FillColor	string
	Thickness	float64
	Style		string
	Layer		string
	HiddenOnPlanner	bool
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meDrawingCreateArrowFlags() (*flag.FlagSet, *meDrawingCreateArrowOpts) {
	opts := &meDrawingCreateArrowOpts{}
	fs := flag.NewFlagSet("me drawing create-arrow", flag.ContinueOnError)
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin (arrow anchor)")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin (arrow anchor)")
	fs.Float64Var(&opts.Length, "length", 0, "arrow length in meters")
	fs.Float64Var(&opts.Angle, "angle", 0, "rotation in degrees (0 = pointing north, CW positive)")
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
	registerMeInfo("drawing", "create-arrow", cmdInfo{
		Run:		meDrawingCreateArrowCmd,
		Flags:		flagsOnly(meDrawingCreateArrowFlags),
		Synopsis:	"draw an arrow on the F10 map",
	})
}

// meDrawingCreateArrowCmd implements
// `dcs-sms me drawing create-arrow --north <m> --east <m> --length <m> [...]`.
//
// Arrow-shape polygon. The shape's runtime points are generated from
// length by polygonArrowMakePoints at load time, so the verb only needs
// length + angle (and standard color / style / layer args). --angle
// rotates the arrow tip around the anchor (0 = pointing north,
// clockwise positive in radians).
func meDrawingCreateArrowCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingCreateArrowFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Length <= 0 {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-arrow: --length is required (> 0)")
		return 2
	}

	colorLua, err := parseDrawingColorToHex(opts.Color, 0xFF)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-arrow:", err)
		return 2
	}
	fillLua, err := parseDrawingColorToHex(opts.FillColor, 0x80)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-arrow:", err)
		return 2
	}

	parts := []string{
		fmt.Sprintf("north = %g", opts.North),
		fmt.Sprintf("east = %g", opts.East),
		fmt.Sprintf("length = %g", opts.Length),
		fmt.Sprintf("angle_deg = %g", opts.Angle),
	}
	if opts.Name != "" {
		parts = append(parts, fmt.Sprintf("name = %s", luaQuote(opts.Name)))
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
		parts = append(parts, fmt.Sprintf("style = %s", luaQuote(opts.Style)))
	}
	if opts.Layer != "" {
		parts = append(parts, fmt.Sprintf("layer = %s", luaQuote(opts.Layer)))
	}
	if opts.HiddenOnPlanner {
		parts = append(parts, "hidden_on_planner = true")
	}
	luaArgs := "{ " + strings.Join(parts, ", ") + " }"

	resp, exitCode := runMeVerb("drawing_create_arrow", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
