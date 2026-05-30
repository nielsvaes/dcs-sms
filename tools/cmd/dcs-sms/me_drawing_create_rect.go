package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meDrawingCreateRectOpts struct {
	North		float64
	East		float64
	Width		float64
	Height		float64
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

func meDrawingCreateRectFlags() (*flag.FlagSet, *meDrawingCreateRectOpts) {
	opts := &meDrawingCreateRectOpts{}
	fs := flag.NewFlagSet("me drawing create-rect", flag.ContinueOnError)
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin (rect center)")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin (rect center)")
	fs.Float64Var(&opts.Width, "width", 0, "rect width in meters")
	fs.Float64Var(&opts.Height, "height", 0, "rect height in meters")
	fs.Float64Var(&opts.Angle, "angle", 0, "rotation in degrees (CW around center, 0 = aligned with north/east)")
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
	registerMeInfo("drawing", "create-rect", cmdInfo{
		Run:		meDrawingCreateRectCmd,
		Flags:		flagsOnly(meDrawingCreateRectFlags),
		Synopsis:	"draw a rectangle on the F10 map",
	})
}

// meDrawingCreateRectCmd implements
// `dcs-sms me drawing create-rect --north <m> --east <m> --width <m> --height <m> [...]`.
//
// Axis-aligned rectangle (or rotated via --angle). Same color / style /
// layer convention as create-circle.
func meDrawingCreateRectCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingCreateRectFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Width <= 0 || opts.Height <= 0 {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-rect: --width and --height are required (> 0)")
		return 2
	}

	colorLua, err := parseDrawingColorToHex(opts.Color, 0xFF)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-rect:", err)
		return 2
	}
	fillLua, err := parseDrawingColorToHex(opts.FillColor, 0x80)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-rect:", err)
		return 2
	}

	parts := []string{
		fmt.Sprintf("north = %g", opts.North),
		fmt.Sprintf("east = %g", opts.East),
		fmt.Sprintf("width = %g", opts.Width),
		fmt.Sprintf("height = %g", opts.Height),
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

	resp, exitCode := runMeVerb("drawing_create_rect", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
