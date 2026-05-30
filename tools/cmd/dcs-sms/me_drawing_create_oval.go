package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meDrawingCreateOvalOpts struct {
	North		float64
	East		float64
	R1		float64
	R2		float64
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

func meDrawingCreateOvalFlags() (*flag.FlagSet, *meDrawingCreateOvalOpts) {
	opts := &meDrawingCreateOvalOpts{}
	fs := flag.NewFlagSet("me drawing create-oval", flag.ContinueOnError)
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin (oval center)")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin (oval center)")
	fs.Float64Var(&opts.R1, "r1", 0, "first semi-axis in meters (along local north pre-rotation)")
	fs.Float64Var(&opts.R2, "r2", 0, "second semi-axis in meters (along local east pre-rotation)")
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
	registerMeInfo("drawing", "create-oval", cmdInfo{
		Run:		meDrawingCreateOvalCmd,
		Flags:		flagsOnly(meDrawingCreateOvalFlags),
		Synopsis:	"draw an oval on the F10 map",
	})
}

// meDrawingCreateOvalCmd implements
// `dcs-sms me drawing create-oval --north <m> --east <m> --r1 <m> --r2 <m> [...]`.
//
// Ellipse with semi-axes r1 (along local X / north before rotation) and
// r2 (along local Y / east before rotation). Setting r1 = r2 produces a
// circle but with the oval-shape control surface; for plain circles use
// create-circle which only takes one radius.
func meDrawingCreateOvalCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingCreateOvalFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.R1 <= 0 || opts.R2 <= 0 {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-oval: --r1 and --r2 are required (> 0)")
		return 2
	}

	colorLua, err := parseDrawingColorToHex(opts.Color, 0xFF)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-oval:", err)
		return 2
	}
	fillLua, err := parseDrawingColorToHex(opts.FillColor, 0x80)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-oval:", err)
		return 2
	}

	parts := []string{
		fmt.Sprintf("north = %g", opts.North),
		fmt.Sprintf("east = %g", opts.East),
		fmt.Sprintf("r1 = %g", opts.R1),
		fmt.Sprintf("r2 = %g", opts.R2),
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

	resp, exitCode := runMeVerb("drawing_create_oval", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
